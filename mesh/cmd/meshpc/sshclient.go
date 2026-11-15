package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"strings"

	sftpclient "github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/term"

	"yousj-mesh/internal/client"
	"yousj-mesh/internal/proto"
)

// resolvePeer finds a member by display name, device id, or virtual IP.
func resolvePeer(c *client.Client, n *client.Network, target string) (*proto.Member, error) {
	resp, err := c.Members(n)
	if err != nil {
		return nil, err
	}
	for i, m := range resp.Members {
		if m.Name == target || m.DeviceID == target || m.VIP == target {
			return &resp.Members[i], nil
		}
	}
	return nil, fmt.Errorf("peer %q not found in network %s", target, n.Name)
}

// dialPeer opens an SSH connection to a member, verifying the host key
// against the identity key registered with the coordinator.
func dialPeer(c *client.Client, n *client.Network, m *proto.Member) (*ssh.Client, error) {
	signer, err := ssh.NewSignerFromKey(c.Identity().IDPriv)
	if err != nil {
		return nil, err
	}
	raw, err := proto.B64.DecodeString(m.IDPub)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("peer %s has a corrupt identity key", m.Name)
	}
	want, err := ssh.NewPublicKey(ed25519.PublicKey(raw))
	if err != nil {
		return nil, err
	}
	cfg := &ssh.ClientConfig{
		User: "mesh",
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback: func(hostname string, remote net.Addr, key ssh.PublicKey) error {
			if string(key.Marshal()) != string(want.Marshal()) {
				return fmt.Errorf("host key mismatch for %s (possible impersonation)", m.Name)
			}
			return nil
		},
	}
	return ssh.Dial("tcp", fmt.Sprintf("%s:%d", m.VIP, proto.SSHPort), cfg)
}

func cmdSSH(args []string) {
	if len(args) < 1 {
		fatal(fmt.Errorf("usage: meshpc ssh <peer> [-- command...]"))
	}
	c := load()
	n := mustActive(c)
	m, err := resolvePeer(c, n, args[0])
	if err != nil {
		fatal(err)
	}
	conn, err := dialPeer(c, n, m)
	if err != nil {
		fatal(fmt.Errorf("ssh to %s (%s): %w", m.Name, m.VIP, err))
	}
	defer conn.Close()
	sess, err := conn.NewSession()
	if err != nil {
		fatal(err)
	}
	defer sess.Close()
	rest := args[1:]
	if len(rest) > 0 && rest[0] == "--" {
		rest = rest[1:]
	}
	if len(rest) > 0 {
		out, err := sess.CombinedOutput(strings.Join(rest, " "))
		fmt.Print(string(out))
		if err != nil {
			if ee, ok := err.(*ssh.ExitError); ok {
				os.Exit(ee.ExitStatus())
			}
			fatal(err)
		}
		return
	}
	// Interactive session.
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		old, err := term.MakeRaw(fd)
		if err == nil {
			defer term.Restore(fd, old)
		}
		w, h, _ := term.GetSize(fd)
		if err := sess.RequestPty("xterm", h, w, ssh.TerminalModes{}); err != nil {
			fatal(err)
		}
	}
	sess.Stdin = os.Stdin
	sess.Stdout = os.Stdout
	sess.Stderr = os.Stderr
	if err := sess.Shell(); err != nil {
		fatal(err)
	}
	_ = sess.Wait()
}

func parsePeerPath(c *client.Client, n *client.Network, spec string) (*proto.Member, string, error) {
	i := strings.Index(spec, ":")
	if i < 0 {
		return nil, "", fmt.Errorf("expected <peer>:<path>, got %q", spec)
	}
	m, err := resolvePeer(c, n, spec[:i])
	if err != nil {
		return nil, "", err
	}
	return m, spec[i+1:], nil
}

func cmdPutGet(args []string, isPut bool) {
	if len(args) < 2 {
		if isPut {
			fatal(fmt.Errorf("usage: meshpc put <local> <peer>:<remote>"))
		}
		fatal(fmt.Errorf("usage: meshpc get <peer>:<remote> <local>"))
	}
	c := load()
	n := mustActive(c)
	var m *proto.Member
	var remotePath, localPath string
	var err error
	if isPut {
		localPath = args[0]
		m, remotePath, err = parsePeerPath(c, n, args[1])
	} else {
		m, remotePath, err = parsePeerPath(c, n, args[0])
		localPath = args[1]
	}
	if err != nil {
		fatal(err)
	}
	conn, err := dialPeer(c, n, m)
	if err != nil {
		fatal(fmt.Errorf("connect %s: %w", m.Name, err))
	}
	defer conn.Close()
	sc, err := sftpclient.NewClient(conn)
	if err != nil {
		fatal(err)
	}
	defer sc.Close()

	if isPut {
		src, err := os.Open(localPath)
		if err != nil {
			fatal(err)
		}
		defer src.Close()
		dst, err := sc.Create(remotePath)
		if err != nil {
			fatal(fmt.Errorf("create remote: %w", err))
		}
		h := sha256.New()
		written, err := io.Copy(io.MultiWriter(dst, h), src)
		_ = dst.Close()
		if err != nil {
			fatal(fmt.Errorf("upload: %w", err))
		}
		fmt.Printf("put %s -> %s:%s (%d bytes, sha256=%s)\n", localPath, m.Name, remotePath, written, hex.EncodeToString(h.Sum(nil)))
		return
	}
	src, err := sc.Open(remotePath)
	if err != nil {
		fatal(fmt.Errorf("open remote: %w", err))
	}
	defer src.Close()
	dst, err := os.Create(localPath)
	if err != nil {
		fatal(err)
	}
	h := sha256.New()
	written, err := io.Copy(io.MultiWriter(dst, h), src)
	_ = dst.Close()
	if err != nil {
		fatal(fmt.Errorf("download: %w", err))
	}
	fmt.Printf("get %s:%s -> %s (%d bytes, sha256=%s)\n", m.Name, remotePath, localPath, written, hex.EncodeToString(h.Sum(nil)))
}
