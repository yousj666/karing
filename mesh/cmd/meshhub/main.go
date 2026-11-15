// yousj-mesh-hub: the relay hub for Yousj Mesh (wireguard-go, userspace).
//
// The hub is a WireGuard peer for every member of every network served by
// its meshd. It polls meshd's hub endpoint (hub token), decrypts each
// network's hub-sealed PSK with its own private key, and reconciles its
// peer table. Member-to-member packets are decrypted and re-encrypted here
// (hub-and-spoke), so the hub host must have IP forwarding enabled.
// Exit policy routing (a member's chosen exit) is reconciled via `ip rule`
// on Linux; see exit_linux.go.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"yousj-mesh/internal/proto"

	"golang.org/x/crypto/curve25519"
)

type hubPeer struct {
	NetworkID    string `json:"network_id"`
	DeviceID     string `json:"device_id"`
	WGPub        string `json:"wg_pub"`
	VIP          string `json:"vip"`
	PSKForHub    string `json:"psk_for_hub"`
	ExitOffering bool   `json:"exit_offering"`
	ExitChoice   string `json:"exit_choice"`
}

var (
	flagMeshd    = flag.String("meshd", "", "meshd base URL")
	flagToken    = flag.String("token", "", "hub token (or env MESHHUB_TOKEN)")
	flagPrivFile = flag.String("privkey-file", "", "file with hub X25519 private key (base64 raw-url or hex)")
	flagPort     = flag.Int("port", 51821, "WireGuard listen port")
	flagIface    = flag.String("iface", "meshhub0", "TUN interface name")
	flagAddr     = flag.String("addr", proto.HubIP+"/24", "hub virtual address")
	flagInterval = flag.Int("interval", 10, "peer sync interval seconds")
	flagInsecure = flag.Bool("insecure", false, "skip TLS verification for meshd (self-signed)")
)

func fatalf(format string, args ...any) {
	log.Fatalf("meshhub: "+format, args...)
}

func loadPrivKey() ([]byte, string) {
	path := *flagPrivFile
	if path == "" {
		fatalf("-privkey-file is required")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fatalf("read privkey: %v", err)
	}
	s := strings.TrimSpace(string(raw))
	if b, err := proto.B64.DecodeString(s); err == nil && len(b) == 32 {
		return b, hex.EncodeToString(b)
	}
	if b, err := hex.DecodeString(s); err == nil && len(b) == 32 {
		return b, s
	}
	fatalf("privkey file must contain a 32-byte key (base64 raw-url or hex)")
	return nil, ""
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "genkey" {
		priv := make([]byte, 32)
		if _, err := rand.Read(priv); err != nil {
			fatalf("rng: %v", err)
		}
		pub, err := curve25519.X25519(priv, curve25519.Basepoint)
		if err != nil {
			fatalf("derive pubkey: %v", err)
		}
		fmt.Printf("private: %s\npublic:  %s\n", proto.B64.EncodeToString(priv), proto.B64.EncodeToString(pub))
		return
	}
	flag.Parse()
	meshd := *flagMeshd
	if meshd == "" {
		meshd = os.Getenv("MESHD_URL")
	}
	token := *flagToken
	if token == "" {
		token = os.Getenv("MESHHUB_TOKEN")
	}
	if meshd == "" || token == "" {
		fatalf("-meshd and -token (or MESHD_URL/MESHHUB_TOKEN) are required")
	}
	priv, privHex := loadPrivKey()

	tunDev, err := tun.CreateTUN(*flagIface, device.DefaultMTU)
	if err != nil {
		fatalf("create tun: %v", err)
	}
	logger := device.NewLogger(device.LogLevelError, "meshhub: ")
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	cfg := fmt.Sprintf("private_key=%s\nlisten_port=%d\nreplace_peers=true\n", privHex, *flagPort)
	if err := dev.IpcSet(cfg); err != nil {
		fatalf("configure device: %v", err)
	}
	if err := dev.Up(); err != nil {
		fatalf("device up: %v", err)
	}
	realName, _ := tunDev.Name()
	if err := assignAddr(realName, *flagAddr); err != nil {
		fatalf("assign %s: %v (need root + iproute2)", *flagAddr, err)
	}
	ensureForwardRule(realName)
	log.Printf("hub up: iface=%s addr=%s port=%d meshd=%s", realName, *flagAddr, *flagPort, meshd)

	httpClient := &http.Client{Timeout: 10 * time.Second}
	if *flagInsecure {
		httpClient.Transport = insecureTransport()
	}
	lastCfg := ""
	for {
		peers, err := fetchPeers(httpClient, meshd, token)
		if err != nil {
			log.Printf("sync: %v", err)
		} else {
			uapi, err := buildHubUAPI(privHex, *flagPort, peers, priv)
			if err != nil {
				log.Printf("build config: %v", err)
			} else if uapi != lastCfg {
				if err := dev.IpcSet(uapi); err != nil {
					log.Printf("apply config: %v", err)
				} else {
					lastCfg = uapi
					log.Printf("synced %d peers", len(peers))
				}
			}
			reconcileExitRules(peers)
		}
		time.Sleep(time.Duration(*flagInterval) * time.Second)
	}
}

func fetchPeers(hc *http.Client, meshd, token string) ([]hubPeer, error) {
	req, err := http.NewRequest("GET", strings.TrimRight(meshd, "/")+"/v1/hub/peers", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Hub-Token", token)
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("meshd %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	var out struct {
		Peers []hubPeer `json:"peers"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out.Peers, nil
}

func buildHubUAPI(privHex string, port int, peers []hubPeer, priv []byte) (string, error) {
	pskByNetwork := map[string]string{}
	for _, p := range peers {
		if _, ok := pskByNetwork[p.NetworkID]; ok {
			continue
		}
		if p.PSKForHub == "" {
			continue
		}
		psk, err := proto.OpenPSKFromHub(p.PSKForHub, priv)
		if err != nil {
			return "", fmt.Errorf("open psk for network %s: %w", p.NetworkID, err)
		}
		pskByNetwork[p.NetworkID] = hex.EncodeToString(psk)
	}
	sorted := append([]hubPeer(nil), peers...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].VIP < sorted[j].VIP })
	// Members currently chosen as an exit by at least one other member get
	// 0.0.0.0/0 in their hub-side allowed_ips: WireGuard selects the outgoing
	// peer by inner destination, so egress traffic (arbitrary internet IPs)
	// can only be steered to the exit peer this way. Member /32s still win
	// by longest-prefix match for mesh-internal traffic. If several exits
	// are chosen simultaneously, internet-bound packets may leave via any
	// of them (documented phase-1 limitation).
	chosenExits := map[string]bool{}
	for _, p := range peers {
		if p.ExitChoice != "" && p.ExitChoice != p.DeviceID {
			chosenExits[p.ExitChoice] = true
		}
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "private_key=%s\nlisten_port=%d\nreplace_peers=true\n", privHex, port)
	for _, p := range sorted {
		pubRaw, err := proto.B64.DecodeString(p.WGPub)
		if err != nil {
			return "", fmt.Errorf("peer %s bad wg key: %w", p.DeviceID, err)
		}
		fmt.Fprintf(&sb, "public_key=%s\n", hex.EncodeToString(pubRaw))
		if pskHex, ok := pskByNetwork[p.NetworkID]; ok {
			fmt.Fprintf(&sb, "preshared_key=%s\n", pskHex)
		}
		fmt.Fprintf(&sb, "allowed_ip=%s/32\n", p.VIP)
		if chosenExits[p.DeviceID] {
			sb.WriteString("allowed_ip=0.0.0.0/0\n")
		}
	}
	return sb.String(), nil
}
