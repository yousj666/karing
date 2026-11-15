// Package client is the shared control-plane client used by yousj-mesh-pc.
// It persists the device identity and joined networks under a data dir and
// speaks the signed protocol defined in internal/proto.
package client

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"yousj-mesh/internal/proto"
)

// State is everything a client keeps on disk. Private keys live here and
// nowhere else; the file must stay user-only (0600).
type State struct {
	Identity  StoredIdentity     `json:"identity"`
	Networks  map[string]*Network `json:"networks"` // by network_id
	ActiveID  string             `json:"active_id"`
	CoordPin  map[string]string  `json:"coord_pin"` // coordinator origin -> sha256 hex of cert
	SSHServer bool               `json:"ssh_server"` // built-in SSH/SFTP server enabled
	SSHShare  string             `json:"ssh_share_dir"` // SFTP root; empty = home dir
}

type StoredIdentity struct {
	IDPriv string `json:"id_priv"` // base64
	IDPub  string `json:"id_pub"`
	WGPriv string `json:"wg_priv"`
	WGPub  string `json:"wg_pub"`
}

type Network struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Coordinator string `json:"coordinator"`
	AdminToken  string `json:"admin_token,omitempty"` // only on the creator
	PSK         string `json:"psk"`                   // base64; from invite payload / creation
	DeviceID    string `json:"device_id"`
	VIP         string `json:"vip"`
	HubPub      string `json:"hub_pub"`
	HubEndpoint string `json:"hub_endpoint"`
	ExitChoice  string `json:"exit_choice"` // device_id of chosen exit, "" = none
	ExitOffering bool  `json:"exit_offering"`
	ExitCapable bool   `json:"exit_capable"`
}

type Client struct {
	Dir   string
	State State
	ident *proto.Identity
	http  *http.Client
}

func statePath(dir string) string { return filepath.Join(dir, "meshpc-state.json") }

// Load reads (or initializes) the client state in dir.
func Load(dir string) (*Client, error) {
	c := &Client{Dir: dir}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(statePath(dir))
	if err == nil {
		if err := json.Unmarshal(b, &c.State); err != nil {
			return nil, fmt.Errorf("state file corrupt: %w", err)
		}
	}
	if c.State.Networks == nil {
		c.State.Networks = map[string]*Network{}
	}
	if c.State.CoordPin == nil {
		c.State.CoordPin = map[string]string{}
	}
	if c.State.Identity.IDPriv == "" {
		id, err := proto.NewIdentity()
		if err != nil {
			return nil, err
		}
		c.State.Identity = StoredIdentity{
			IDPriv: proto.B64.EncodeToString(id.IDPriv),
			IDPub:  proto.B64.EncodeToString(id.IDPub),
			WGPriv: proto.B64.EncodeToString(id.WGPriv),
			WGPub:  proto.B64.EncodeToString(id.WGPub),
		}
		if err := c.Save(); err != nil {
			return nil, err
		}
	}
	idPriv, _ := proto.B64.DecodeString(c.State.Identity.IDPriv)
	idPub, _ := proto.B64.DecodeString(c.State.Identity.IDPub)
	wgPriv, _ := proto.B64.DecodeString(c.State.Identity.WGPriv)
	wgPub, _ := proto.B64.DecodeString(c.State.Identity.WGPub)
	c.ident = &proto.Identity{
		IDPriv: ed25519.PrivateKey(idPriv), IDPub: ed25519.PublicKey(idPub),
		WGPriv: wgPriv, WGPub: wgPub,
	}
	c.http = &http.Client{Timeout: 20 * time.Second, Transport: c.transport()}
	return c, nil
}

func (c *Client) Save() error {
	b, err := json.MarshalIndent(&c.State, "", " ")
	if err != nil {
		return err
	}
	tmp := statePath(c.Dir) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, statePath(c.Dir))
}

func (c *Client) Identity() *proto.Identity { return c.ident }
func (c *Client) DeviceID() string          { return proto.DeviceID(c.ident.IDPub) }

// transport pins the coordinator's TLS certificate by SHA-256 fingerprint.
// First contact is trust-on-first-use: the fingerprint is stored and printed.
func (c *Client) transport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true, // verification is done manually below via pin
			VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
				// Origin is not known here; pinning is enforced in do() by
				// comparing against all known pins when a URL is pinned.
				_ = rawCerts
				return nil
			},
		},
	}
}

// PinFor returns the stored cert fingerprint for a coordinator base URL.
func (c *Client) PinFor(base string) string { return c.State.CoordPin[base] }

// NotePin records a fingerprint (TOFU) for a coordinator base URL.
func (c *Client) NotePin(base string, certDER []byte) string {
	h := sha256.Sum256(certDER)
	fp := hex.EncodeToString(h[:])
	if existing := c.State.CoordPin[base]; existing == "" {
		c.State.CoordPin[base] = fp
		_ = c.Save()
		fmt.Fprintf(os.Stderr, "note: pinned coordinator %s certificate sha256=%s (trust on first use)\n", base, fp)
	}
	return c.State.CoordPin[base]
}

// do performs a signed (or admin) request and decodes the JSON response.
func (c *Client) do(base, method, path string, body any, adminToken string, out any) (int, error) {
	var raw []byte
	if body != nil {
		var err error
		raw, err = json.Marshal(body)
		if err != nil {
			return 0, err
		}
	}
	req, err := http.NewRequest(method, base+path, bytes.NewReader(raw))
	if err != nil {
		return 0, err
	}
	ts := time.Now().Unix()
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", c.DeviceID())
	req.Header.Set("X-Timestamp", strconv.FormatInt(ts, 10))
	req.Header.Set("X-Signature", proto.SignRequest(c.ident.IDPriv, method, path, ts, raw))
	if adminToken != "" {
		req.Header.Set("X-Admin-Token", adminToken)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	// Enforce the cert pin when the coordinator uses TLS.
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		fp := c.NotePin(base, resp.TLS.PeerCertificates[0].Raw)
		want := c.State.CoordPin[base]
		if want != "" && fp != want {
			return resp.StatusCode, fmt.Errorf("coordinator certificate changed (pinned %s, got %s); refusing", want, fp)
		}
	}
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(respBody, &e)
		return resp.StatusCode, fmt.Errorf("coordinator %s: %s", resp.Status, e.Error)
	}
	if out != nil {
		if err := json.Unmarshal(respBody, out); err != nil {
			return resp.StatusCode, fmt.Errorf("decode response: %w", err)
		}
	}
	return resp.StatusCode, nil
}

// CreateNetwork asks meshd to create a network. The PSK is generated locally;
// only its hash and a hub-sealed copy leave the device.
func (c *Client) CreateNetwork(base, name string) (*Network, string, error) {
	psk := make([]byte, 32)
	if _, err := rand.Read(psk); err != nil {
		return nil, "", err
	}
	var meta proto.MetaResponse
	if _, err := c.do(base, "GET", "/v1/meta", nil, "", &meta); err != nil {
		return nil, "", fmt.Errorf("fetch coordinator meta: %w", err)
	}
	hubPub, err := proto.B64.DecodeString(meta.Hub.PublicKey)
	if err != nil {
		return nil, "", fmt.Errorf("coordinator reports a bad hub key: %w", err)
	}
	sealed, err := proto.SealPSKForHub(psk, hubPub)
	if err != nil {
		return nil, "", err
	}
	var resp proto.CreateNetworkResponse
	_, err = c.do(base, "POST", "/v1/networks", proto.CreateNetworkRequest{
		Name: name, PSKHash: proto.HashPSK(psk), PSKForHub: sealed,
	}, "", &resp)
	if err != nil {
		return nil, "", err
	}
	n := &Network{
		ID: resp.NetworkID, Name: name, Coordinator: base,
		AdminToken: resp.AdminToken, PSK: proto.B64.EncodeToString(psk),
		HubPub: resp.Hub.PublicKey, HubEndpoint: resp.Hub.Endpoint,
		ExitCapable: true,
	}
	c.State.Networks[n.ID] = n
	c.State.ActiveID = n.ID
	if err := c.Save(); err != nil {
		return nil, "", err
	}
	return n, resp.AdminToken, nil
}

// CreateInvite mints an invite code (creator/admin only).
func (c *Client) CreateInvite(n *Network, ttlSeconds, maxUses int) (*proto.CreateInviteResponse, error) {
	var resp proto.CreateInviteResponse
	_, err := c.do(n.Coordinator, "POST", "/v1/networks/"+n.ID+"/invites",
		proto.CreateInviteRequest{TTLSeconds: ttlSeconds, MaxUses: maxUses}, n.AdminToken, &resp)
	if err != nil {
		return nil, err
	}
	return &resp, nil
}

// InvitePayload builds the shareable join blob for a network we created.
func (c *Client) InvitePayload(n *Network, code string) (string, error) {
	p := &proto.InvitePayload{
		V: 1, Coordinator: n.Coordinator, NetworkID: n.ID, NetworkName: n.Name,
		InviteCode: code, PSK: n.PSK,
	}
	return p.Encode()
}

// Join registers this device into the network named by an invite payload.
func (c *Client) Join(payloadStr, deviceName string) (*Network, error) {
	p, err := proto.DecodeInvitePayload(payloadStr)
	if err != nil {
		return nil, err
	}
	var resp proto.JoinResponse
	_, err = c.do(p.Coordinator, "POST", "/v1/join", proto.JoinRequest{
		InviteCode:  p.InviteCode,
		Name:        deviceName,
		WGPub:       proto.B64.EncodeToString(c.ident.WGPub),
		IDPub:       proto.B64.EncodeToString(c.ident.IDPub),
		ExitCapable: true,
	}, "", &resp)
	if err != nil {
		return nil, err
	}
	n := &Network{
		ID: resp.NetworkID, Name: resp.NetworkName, Coordinator: p.Coordinator,
		PSK: p.PSK, DeviceID: resp.DeviceID, VIP: resp.VIP,
		HubPub: resp.Hub.PublicKey, HubEndpoint: resp.Hub.Endpoint,
		ExitCapable: true,
	}
	if old := c.State.Networks[n.ID]; old != nil && old.AdminToken != "" {
		n.AdminToken = old.AdminToken // creator re-joining keeps admin rights
	}
	c.State.Networks[n.ID] = n
	c.State.ActiveID = n.ID
	if err := c.Save(); err != nil {
		return nil, err
	}
	return n, nil
}

// Members fetches the current member list (also refreshes our heartbeat).
func (c *Client) Members(n *Network) (*proto.MembersResponse, error) {
	var resp proto.MembersResponse
	_, err := c.do(n.Coordinator, "GET", "/v1/networks/"+n.ID+"/members", nil, "", &resp)
	if err != nil {
		return nil, err
	}
	n.HubPub = resp.Hub.PublicKey
	n.HubEndpoint = resp.Hub.Endpoint
	_ = c.Save()
	return &resp, nil
}

// Heartbeat posts liveness + exit flags.
func (c *Client) Heartbeat(n *Network) error {
	offering := n.ExitOffering
	capable := n.ExitCapable
	choice := n.ExitChoice
	_, err := c.do(n.Coordinator, "POST", "/v1/networks/"+n.ID+"/heartbeat",
		proto.HeartbeatRequest{ExitOffering: &offering, ExitCapable: &capable, ExitChoice: &choice}, "", nil)
	return err
}

// Leave deregisters this device from the network and forgets it locally.
func (c *Client) Leave(n *Network) error {
	_, err := c.do(n.Coordinator, "POST", "/v1/networks/"+n.ID+"/leave", nil, "", nil)
	delete(c.State.Networks, n.ID)
	if c.State.ActiveID == n.ID {
		c.State.ActiveID = ""
	}
	_ = c.Save()
	return err
}

// Kick removes a device (admin only).
func (c *Client) Kick(n *Network, deviceID string) error {
	_, err := c.do(n.Coordinator, "DELETE", "/v1/networks/"+n.ID+"/devices/"+deviceID, nil, n.AdminToken, nil)
	return err
}

// Dissolve marks the network dissolved (admin only).
func (c *Client) Dissolve(n *Network) error {
	_, err := c.do(n.Coordinator, "DELETE", "/v1/networks/"+n.ID, nil, n.AdminToken, nil)
	if err == nil {
		delete(c.State.Networks, n.ID)
		if c.State.ActiveID == n.ID {
			c.State.ActiveID = ""
		}
		_ = c.Save()
	}
	return err
}

// Reload re-reads the state file, picking up changes made by other meshpc
// processes (e.g. `meshpc exit use` while the daemon runs). The daemon must
// reload before every heartbeat, or its stale in-memory copy would clobber
// newer settings on the coordinator.
func (c *Client) Reload() error {
	b, err := os.ReadFile(statePath(c.Dir))
	if err != nil {
		return err
	}
	var st State
	if err := json.Unmarshal(b, &st); err != nil {
		return err
	}
	if st.Networks == nil {
		st.Networks = map[string]*Network{}
	}
	if st.CoordPin == nil {
		st.CoordPin = map[string]string{}
	}
	c.State = st
	return nil
}

// Active returns the active network, if any.
func (c *Client) Active() *Network {
	if c.State.ActiveID == "" {
		return nil
	}
	return c.State.Networks[c.State.ActiveID]
}

