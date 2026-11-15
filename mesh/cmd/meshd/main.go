// yousj-meshd: the self-developed coordination service for Yousj Mesh.
//
// It only handles the control plane: networks, invite codes, the device
// registry, virtual-IP allocation and member-list distribution. It never
// sees data-plane traffic and never holds any device private key or the
// network PSK (only its SHA-256 hash).
package main

import (
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"yousj-mesh/internal/proto"
)

type Config struct {
	Listen     string `json:"listen"`      // e.g. ":18790"
	DataFile   string `json:"data_file"`   // JSON state file
	HubPubKey  string `json:"hub_pubkey"`  // base64 raw-url X25519 public key of the relay hub
	HubEndpoint string `json:"hub_endpoint"` // public host:port of the hub
	HubToken   string `json:"hub_token"`   // shared secret for GET /v1/hub/peers
	TLSCert    string `json:"tls_cert"`    // optional; empty = plain HTTP (warn)
	TLSKey     string `json:"tls_key"`
}

type Device struct {
	DeviceID     string `json:"device_id"`
	Name         string `json:"name"`
	VIP          string `json:"vip"`
	WGPub        string `json:"wg_pub"`
	IDPub        string `json:"id_pub"`
	ExitCapable  bool   `json:"exit_capable"`
	ExitOffering bool   `json:"exit_offering"`
	ExitChoice   string `json:"exit_choice"`
	LastSeen     int64  `json:"last_seen"`
	JoinedAt     int64  `json:"joined_at"`
}

type Invite struct {
	Code      string `json:"code"`
	ExpiresAt int64  `json:"expires_at"`
	MaxUses   int    `json:"max_uses"`
	Uses      int    `json:"uses"`
	Revoked   bool   `json:"revoked"`
	RedeemedBy []string `json:"redeemed_by"`
}

type Network struct {
	ID         string             `json:"id"`
	Name       string             `json:"name"`
	PSKHash    string             `json:"psk_hash"`
	PSKForHub  string             `json:"psk_for_hub"`
	AdminToken string             `json:"admin_token"`
	Dissolved  bool               `json:"dissolved"`
	CreatedAt  int64              `json:"created_at"`
	Devices    map[string]*Device `json:"devices"` // by device_id
	Invites    map[string]*Invite `json:"invites"` // by code
	Released   map[string]int64   `json:"released"` // vip -> release unix time (24h hold)
}

type Store struct {
	Networks map[string]*Network `json:"networks"`
}

type Server struct {
	cfg   Config
	mu    sync.Mutex
	store Store
}

func main() {
	cfgPath := flag.String("config", "meshd.json", "config file path")
	flag.Parse()
	raw, err := os.ReadFile(*cfgPath)
	if err != nil {
		log.Fatalf("read config: %v", err)
	}
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatalf("parse config: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":18790"
	}
	if cfg.DataFile == "" {
		cfg.DataFile = "meshd-data.json"
	}
	s := &Server{cfg: cfg}
	s.store.Networks = map[string]*Network{}
	if b, err := os.ReadFile(cfg.DataFile); err == nil {
		if err := json.Unmarshal(b, &s.store); err != nil {
			log.Fatalf("parse data file: %v", err)
		}
		if s.store.Networks == nil {
			s.store.Networks = map[string]*Network{}
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "service": "yousj-meshd", "version": "1.0.0"})
	})
	mux.HandleFunc("GET /v1/meta", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, proto.MetaResponse{Hub: proto.HubInfo{PublicKey: s.cfg.HubPubKey, Endpoint: s.cfg.HubEndpoint}})
	})
	mux.HandleFunc("POST /v1/networks", s.handleCreateNetwork)
	mux.HandleFunc("POST /v1/networks/{id}/invites", s.adminOnly(s.handleCreateInvite))
	mux.HandleFunc("DELETE /v1/networks/{id}/invites/{code}", s.adminOnly(s.handleRevokeInvite))
	mux.HandleFunc("POST /v1/join", s.handleJoin)
	mux.HandleFunc("GET /v1/networks/{id}/members", s.memberOnly(s.handleMembers))
	mux.HandleFunc("POST /v1/networks/{id}/heartbeat", s.memberOnly(s.handleHeartbeat))
	mux.HandleFunc("POST /v1/networks/{id}/leave", s.memberOnly(s.handleLeave))
	mux.HandleFunc("DELETE /v1/networks/{id}/devices/{dev}", s.adminOnly(s.handleKick))
	mux.HandleFunc("DELETE /v1/networks/{id}", s.adminOnly(s.handleDissolve))
	mux.HandleFunc("GET /v1/hub/peers", s.handleHubPeers)

	log.Printf("yousj-meshd listening on %s (hub endpoint %s)", cfg.Listen, cfg.HubEndpoint)
	if cfg.TLSCert != "" && cfg.TLSKey != "" {
		log.Fatal(http.ListenAndServeTLS(cfg.Listen, cfg.TLSCert, cfg.TLSKey, mux))
	}
	log.Printf("WARNING: serving plain HTTP; put meshd behind HTTPS in production")
	log.Fatal(http.ListenAndServe(cfg.Listen, mux))
}

func (s *Server) save() {
	b, err := json.MarshalIndent(&s.store, "", " ")
	if err != nil {
		log.Printf("marshal store: %v", err)
		return
	}
	tmp := s.cfg.DataFile + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		log.Printf("write store: %v", err)
		return
	}
	_ = os.Rename(tmp, s.cfg.DataFile)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"ok": false, "error": msg})
}

func readBody(r *http.Request) []byte {
	b, _ := readAll(r)
	return b
}

func readAll(r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	for {
		n, err := r.Body.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if err != nil {
			break
		}
		if len(buf) > 1<<20 {
			break
		}
	}
	return buf, nil
}

// ---- auth wrappers ----

// adminOnly requires the network admin token (creator).
func (s *Server) adminOnly(next func(http.ResponseWriter, *http.Request, *Network)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		net := s.store.Networks[r.PathValue("id")]
		if net == nil {
			writeErr(w, 404, "network not found")
			return
		}
		tok := r.Header.Get("X-Admin-Token")
		if tok == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(net.AdminToken)) != 1 {
			writeErr(w, 401, "bad admin token")
			return
		}
		next(w, r, net)
	}
}

// memberOnly requires a valid device signature from a registered member.
// The body is read once here and stashed for the handler via a wrapped request.
func (s *Server) memberOnly(next func(http.ResponseWriter, *http.Request, *Network, *Device)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body := readBody(r)
		s.mu.Lock()
		defer s.mu.Unlock()
		net := s.store.Networks[r.PathValue("id")]
		if net == nil {
			writeErr(w, 404, "network not found")
			return
		}
		devID := r.Header.Get("X-Device-Id")
		dev := net.Devices[devID]
		if dev == nil {
			writeErr(w, 401, "not a member")
			return
		}
		pubRaw, err := proto.B64.DecodeString(dev.IDPub)
		if err != nil || len(pubRaw) != ed25519.PublicKeySize {
			writeErr(w, 500, "stored identity key corrupt")
			return
		}
		ts, _ := strconv.ParseInt(r.Header.Get("X-Timestamp"), 10, 64)
		if err := proto.VerifyRequest(ed25519.PublicKey(pubRaw), r.Method, r.URL.Path, r.Header.Get("X-Signature"), ts, body); err != nil {
			writeErr(w, 401, "signature check failed: "+err.Error())
			return
		}
		r2 := r.Clone(r.Context())
		r2.Body = &bodyReader{b: body}
		r2.ContentLength = int64(len(body))
		next(w, r2, net, dev)
	}
}

type bodyReader struct {
	b   []byte
	off int
}

func (br *bodyReader) Read(p []byte) (int, error) {
	if br.off >= len(br.b) {
		return 0, io.EOF
	}
	n := copy(p, br.b[br.off:])
	br.off += n
	return n, nil
}
func (br *bodyReader) Close() error { return nil }

// ---- handlers ----

func (s *Server) handleCreateNetwork(w http.ResponseWriter, r *http.Request) {
	var req proto.CreateNetworkRequest
	if err := json.Unmarshal(readBody(r), &req); err != nil || req.Name == "" || req.PSKHash == "" {
		writeErr(w, 400, "name and psk_hash required")
		return
	}
	id, err := proto.NewToken(8)
	if err != nil {
		writeErr(w, 500, "rng failure")
		return
	}
	admin, err := proto.NewToken(24)
	if err != nil {
		writeErr(w, 500, "rng failure")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	net := &Network{
		ID: id, Name: req.Name, PSKHash: req.PSKHash, PSKForHub: req.PSKForHub, AdminToken: admin,
		CreatedAt: time.Now().Unix(),
		Devices:   map[string]*Device{},
		Invites:   map[string]*Invite{},
		Released:  map[string]int64{},
	}
	s.store.Networks[id] = net
	s.save()
	writeJSON(w, 200, proto.CreateNetworkResponse{
		NetworkID: id, AdminToken: admin,
		Hub: proto.HubInfo{PublicKey: s.cfg.HubPubKey, Endpoint: s.cfg.HubEndpoint},
	})
}

func (s *Server) handleCreateInvite(w http.ResponseWriter, r *http.Request, net *Network) {
	if net.Dissolved {
		writeErr(w, 410, "network dissolved")
		return
	}
	var req proto.CreateInviteRequest
	_ = json.Unmarshal(readBody(r), &req)
	if req.TTLSeconds <= 0 {
		req.TTLSeconds = 24 * 3600
	}
	if req.MaxUses <= 0 {
		req.MaxUses = 1
	}
	code, err := proto.NewToken(12)
	if err != nil {
		writeErr(w, 500, "rng failure")
		return
	}
	exp := time.Now().Unix() + int64(req.TTLSeconds)
	net.Invites[code] = &Invite{Code: code, ExpiresAt: exp, MaxUses: req.MaxUses}
	s.save()
	writeJSON(w, 200, proto.CreateInviteResponse{Code: code, ExpiresAt: exp})
}

func (s *Server) handleRevokeInvite(w http.ResponseWriter, r *http.Request, net *Network) {
	inv := net.Invites[r.PathValue("code")]
	if inv == nil {
		writeErr(w, 404, "invite not found")
		return
	}
	inv.Revoked = true
	s.save()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handleJoin(w http.ResponseWriter, r *http.Request) {
	body := readBody(r)
	var req proto.JoinRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeErr(w, 400, "bad join request")
		return
	}
	idPubRaw, err := proto.B64.DecodeString(req.IDPub)
	if err != nil || len(idPubRaw) != ed25519.PublicKeySize {
		writeErr(w, 400, "bad identity public key")
		return
	}
	if _, err := proto.B64.DecodeString(req.WGPub); err != nil {
		writeErr(w, 400, "bad wireguard public key")
		return
	}
	// The join request itself must be signed by the joining device key.
	ts, _ := strconv.ParseInt(r.Header.Get("X-Timestamp"), 10, 64)
	devID := proto.DeviceID(ed25519.PublicKey(idPubRaw))
	if r.Header.Get("X-Device-Id") != devID {
		writeErr(w, 401, "device id does not match identity key")
		return
	}
	if err := proto.VerifyRequest(ed25519.PublicKey(idPubRaw), r.Method, r.URL.Path, r.Header.Get("X-Signature"), ts, body); err != nil {
		writeErr(w, 401, "signature check failed: "+err.Error())
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	// Locate the network by scanning for the invite code (codes are 96-bit random).
	var net *Network
	var inv *Invite
	for _, n := range s.store.Networks {
		if n.Dissolved {
			continue
		}
		if iv, ok := n.Invites[req.InviteCode]; ok {
			net, inv = n, iv
			break
		}
	}
	if net == nil || inv == nil {
		writeErr(w, 404, "invite code not found")
		return
	}
	if inv.Revoked {
		writeErr(w, 403, "invite revoked")
		return
	}
	if time.Now().Unix() > inv.ExpiresAt {
		writeErr(w, 403, "invite expired")
		return
	}
	dev, exists := net.Devices[devID]
	if !exists {
		if inv.Uses >= inv.MaxUses {
			writeErr(w, 403, "invite exhausted")
			return
		}
		vip := net.allocVIP()
		if vip == "" {
			writeErr(w, 507, "network full")
			return
		}
		dev = &Device{
			DeviceID: devID, VIP: vip, JoinedAt: time.Now().Unix(),
		}
		net.Devices[devID] = dev
		inv.Uses++
		inv.RedeemedBy = append(inv.RedeemedBy, devID)
	}
	dev.Name = req.Name
	dev.WGPub = req.WGPub
	dev.IDPub = req.IDPub
	dev.ExitCapable = req.ExitCapable
	dev.LastSeen = time.Now().Unix()
	s.save()
	writeJSON(w, 200, proto.JoinResponse{
		NetworkID: net.ID, NetworkName: net.Name, DeviceID: devID, VIP: dev.VIP,
		Hub:     proto.HubInfo{PublicKey: s.cfg.HubPubKey, Endpoint: s.cfg.HubEndpoint},
		Members: net.memberList(),
	})
}

func (net *Network) allocVIP() string {
	used := map[string]bool{proto.HubIP: true}
	for _, d := range net.Devices {
		used[d.VIP] = true
	}
	now := time.Now().Unix()
	for i := 2; i <= 254; i++ {
		vip := fmt.Sprintf("10.99.0.%d", i)
		if used[vip] {
			continue
		}
		if rel, held := net.Released[vip]; held && now-rel < 24*3600 {
			continue // kicked device's IP stays quarantined for 24h
		}
		delete(net.Released, vip)
		return vip
	}
	return ""
}

func (net *Network) memberList() []proto.Member {
	out := make([]proto.Member, 0, len(net.Devices))
	now := time.Now().Unix()
	for _, d := range net.Devices {
		out = append(out, proto.Member{
			DeviceID: d.DeviceID, Name: d.Name, VIP: d.VIP, WGPub: d.WGPub, IDPub: d.IDPub,
			ExitCapable: d.ExitCapable, ExitOffering: d.ExitOffering,
			Online: now-d.LastSeen <= 90, LastSeen: d.LastSeen,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].VIP < out[j].VIP })
	return out
}

func (s *Server) handleMembers(w http.ResponseWriter, r *http.Request, net *Network, dev *Device) {
	dev.LastSeen = time.Now().Unix()
	s.save()
	code := 200
	if net.Dissolved {
		code = 410
	}
	writeJSON(w, code, proto.MembersResponse{
		NetworkName: net.Name,
		Hub:         proto.HubInfo{PublicKey: s.cfg.HubPubKey, Endpoint: s.cfg.HubEndpoint},
		Members:     net.memberList(),
		Dissolved:   net.Dissolved,
	})
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request, net *Network, dev *Device) {
	if net.Dissolved {
		writeErr(w, 410, "network dissolved")
		return
	}
	var req proto.HeartbeatRequest
	_ = json.Unmarshal(readBody(r), &req)
	if req.ExitCapable != nil {
		dev.ExitCapable = *req.ExitCapable
	}
	if req.ExitOffering != nil {
		dev.ExitOffering = *req.ExitOffering
	}
	if req.ExitChoice != nil {
		dev.ExitChoice = *req.ExitChoice
	}
	dev.LastSeen = time.Now().Unix()
	s.save()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handleLeave(w http.ResponseWriter, r *http.Request, net *Network, dev *Device) {
	net.Released[dev.VIP] = time.Now().Unix()
	delete(net.Devices, dev.DeviceID)
	s.save()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handleKick(w http.ResponseWriter, r *http.Request, net *Network) {
	target := r.PathValue("dev")
	dev := net.Devices[target]
	if dev == nil {
		writeErr(w, 404, "device not found")
		return
	}
	net.Released[dev.VIP] = time.Now().Unix()
	delete(net.Devices, target)
	s.save()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (s *Server) handleDissolve(w http.ResponseWriter, r *http.Request, net *Network) {
	net.Dissolved = true
	s.save()
	writeJSON(w, 200, map[string]any{"ok": true})
}

// handleHubPeers feeds the co-located WireGuard hub: the full peer list for
// every live network (phase 1 deploys one network per hub).
func (s *Server) handleHubPeers(w http.ResponseWriter, r *http.Request) {
	if s.cfg.HubToken == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Hub-Token")), []byte(s.cfg.HubToken)) != 1 {
		writeErr(w, 401, "bad hub token")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	type peer struct {
		NetworkID    string `json:"network_id"`
		DeviceID     string `json:"device_id"`
		WGPub        string `json:"wg_pub"`
		VIP          string `json:"vip"`
		PSKForHub    string `json:"psk_for_hub"`
		ExitOffering bool   `json:"exit_offering"`
		ExitChoice   string `json:"exit_choice"`
	}
	out := []peer{}
	for _, net := range s.store.Networks {
		if net.Dissolved {
			continue
		}
		for _, d := range net.Devices {
			out = append(out, peer{NetworkID: net.ID, DeviceID: d.DeviceID, WGPub: d.WGPub, VIP: d.VIP, PSKForHub: net.PSKForHub, ExitOffering: d.ExitOffering, ExitChoice: d.ExitChoice})
		}
	}
	writeJSON(w, 200, map[string]any{"peers": out})
}

var _ = strings.TrimSpace
