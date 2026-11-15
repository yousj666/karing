package main

import (
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"yousj-mesh/internal/client"
	"yousj-mesh/internal/proto"
)

// sshServer is the built-in SSH/SFTP endpoint every mesh member can run.
// It binds only to the device's mesh virtual IP, accepts only public-key
// auth, and the only accepted keys are the identity keys of current members
// of the same network (the device identity key doubles as the SSH key, so
// no extra credential exists). SFTP is jailed to the configured share dir.
type sshServer struct {
	ln      net.Listener
	cfg     *ssh.ServerConfig
	cli     *client.Client
	netw    *client.Network
	mu      sync.Mutex
	members []proto.Member
	fetched time.Time
}

func startSSHServer(c *client.Client, n *client.Network) (*sshServer, error) {
	s := &sshServer{cli: c, netw: n}
	signer, err := ssh.NewSignerFromKey(c.Identity().IDPriv)
	if err != nil {
		return nil, err
	}
	cfg := &ssh.ServerConfig{
		NoClientAuth: false,
		PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			members, err := s.currentMembers()
			if err != nil {
				return nil, fmt.Errorf("member list unavailable")
			}
			for _, m := range members {
				raw, err := proto.B64.DecodeString(m.IDPub)
				if err != nil || len(raw) != ed25519.PublicKeySize {
					continue
				}
				want, err := ssh.NewPublicKey(ed25519.PublicKey(raw))
				if err != nil {
					continue
				}
				if string(want.Marshal()) == string(key.Marshal()) {
					return &ssh.Permissions{Extensions: map[string]string{"device": m.DeviceID, "name": m.Name}}, nil
				}
			}
			return nil, fmt.Errorf("not a mesh member")
		},
	}
	cfg.AddHostKey(signer)
	s.cfg = cfg
	ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", n.VIP, proto.SSHPort))
	if err != nil {
		return nil, err
	}
	s.ln = ln
	go s.serve()
	return s, nil
}

func (s *sshServer) Close() { _ = s.ln.Close() }

func (s *sshServer) currentMembers() ([]proto.Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.fetched) < 20*time.Second && s.members != nil {
		return s.members, nil
	}
	resp, err := s.cli.Members(s.netw)
	if err != nil {
		if s.members != nil {
			return s.members, nil // serve stale rather than lock everyone out
		}
		return nil, err
	}
	s.members = resp.Members
	s.fetched = time.Now()
	return s.members, nil
}

func (s *sshServer) serve() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.handleConn(conn)
	}
}

func (s *sshServer) handleConn(nConn net.Conn) {
	sshConn, chans, reqs, err := ssh.NewServerConn(nConn, s.cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	shareRoot := s.cli.State.SSHShare
	if shareRoot == "" {
		shareRoot, _ = os.UserHomeDir()
	}
	for ch := range chans {
		if ch.ChannelType() != "session" {
			_ = ch.Reject(ssh.UnknownChannelType, "only session channels")
			continue
		}
		channel, requests, err := ch.Accept()
		if err != nil {
			continue
		}
		go s.handleSession(sshConn, channel, requests, shareRoot)
	}
}

func (s *sshServer) handleSession(conn *ssh.ServerConn, channel ssh.Channel, reqs <-chan *ssh.Request, shareRoot string) {
	defer channel.Close()
	opts := &shellOpts{winCh: make(chan [2]int, 4)}
	for req := range reqs {
		switch req.Type {
		case "subsystem":
			if len(req.Payload) >= 4 && string(req.Payload[4:]) == "sftp" {
				_ = req.Reply(true, nil)
				handlers := sftp.Handlers{
					FileGet:  &jailFS{root: shareRoot},
					FilePut:  &jailFS{root: shareRoot},
					FileList: &jailFS{root: shareRoot},
					FileCmd:  &jailFS{root: shareRoot},
				}
				server := sftp.NewRequestServer(channel, handlers)
				_ = server.Serve()
				return
			}
			_ = req.Reply(false, nil)
		case "exec":
			var payload struct{ Command string }
			if err := ssh.Unmarshal(req.Payload, &payload); err != nil {
				_ = req.Reply(false, nil)
				continue
			}
			_ = req.Reply(true, nil)
			go drainReplies(reqs)
			code := runShell(channel, payload.Command, opts)
			_, _ = channel.SendRequest("exit-status", false, []byte{0, 0, 0, byte(code)})
			return
		case "shell":
			_ = req.Reply(true, nil)
			go drainReplies(reqs)
			code := runShell(channel, "", opts)
			_, _ = channel.SendRequest("exit-status", false, []byte{0, 0, 0, byte(code)})
			return
		case "pty-req":
			var payload struct {
				Term          string
				Columns, Rows uint32
			}
			if err := ssh.Unmarshal(req.Payload, &payload); err == nil {
				opts.pty = true
				opts.cols, opts.rows = int(payload.Columns), int(payload.Rows)
			}
			_ = req.Reply(true, nil)
		case "window-change":
			var payload struct{ Columns, Rows uint32 }
			if err := ssh.Unmarshal(req.Payload, &payload); err == nil {
				select {
				case opts.winCh <- [2]int{int(payload.Columns), int(payload.Rows)}:
				default:
				}
			}
		case "env":
			_ = req.Reply(true, nil)
		default:
			_ = req.Reply(false, nil)
		}
	}
}

type shellOpts struct {
	pty  bool
	cols int
	rows int
	winCh chan [2]int
}

func drainReplies(reqs <-chan *ssh.Request) {
	for r := range reqs {
		_ = r.Reply(false, nil)
	}
}

// ---- jailed SFTP filesystem (rooted at the share dir) ----

type jailFS struct{ root string }

func (j *jailFS) resolve(p string) (string, error) {
	clean := filepath.Clean("/" + strings.TrimPrefix(p, "/"))
	full := filepath.Join(j.root, clean)
	rel, err := filepath.Rel(j.root, full)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", os.ErrPermission
	}
	return full, nil
}

func (j *jailFS) Fileread(req *sftp.Request) (io.ReaderAt, error) {
	full, err := j.resolve(req.Filepath)
	if err != nil {
		return nil, err
	}
	return os.Open(full)
}

func (j *jailFS) Filewrite(req *sftp.Request) (io.WriterAt, error) {
	full, err := j.resolve(req.Filepath)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return nil, err
	}
	return os.OpenFile(full, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
}

type listerAt []os.FileInfo

func (l listerAt) ListAt(ls []os.FileInfo, offset int64) (int, error) {
	if offset >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(ls, l[offset:])
	if n < len(ls) {
		return n, io.EOF
	}
	return n, nil
}

func (j *jailFS) Filelist(req *sftp.Request) (sftp.ListerAt, error) {
	full, err := j.resolve(req.Filepath)
	if err != nil {
		return nil, err
	}
	switch req.Method {
	case "List":
		entries, err := os.ReadDir(full)
		if err != nil {
			return nil, err
		}
		infos := make([]os.FileInfo, 0, len(entries))
		for _, e := range entries {
			fi, err := e.Info()
			if err == nil {
				infos = append(infos, fi)
			}
		}
		return listerAt(infos), nil
	case "Stat":
		fi, err := os.Stat(full)
		if err != nil {
			return nil, err
		}
		return listerAt{fi}, nil
	case "Readlink":
		return nil, fmt.Errorf("readlink not supported")
	}
	return nil, fmt.Errorf("unsupported list method %s", req.Method)
}

func (j *jailFS) Filecmd(req *sftp.Request) error {
	full, err := j.resolve(req.Filepath)
	if err != nil {
		return err
	}
	switch req.Method {
	case "Mkdir":
		return os.MkdirAll(full, 0o755)
	case "Rmdir", "Remove":
		return os.Remove(full)
	case "Rename":
		target, err := j.resolve(req.Target)
		if err != nil {
			return err
		}
		return os.Rename(full, target)
	case "Setstat":
		return nil // accept and ignore attribute changes
	}
	return fmt.Errorf("unsupported file cmd %s", req.Method)
}
