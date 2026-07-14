package membership

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	pb "go.etcd.io/etcd/api/v3/etcdserverpb"
	clientv3 "go.etcd.io/etcd/client/v3"

	"github.com/polarity/qattach/internal/config"
)

const (
	etcdConfigDir  = "/etc/etcd"
	etcdDataDir    = "/var/lib/etcd"
	etcdService    = "etcd.service"
	etcdDropinDir  = "/etc/systemd/system/etcd.service.d"
	etcdArgsFile   = "/etc/etcd/etcd.args"
	healthTimeout  = 30 * time.Second
	healthInterval = 2 * time.Second
)

// Manager handles etcd cluster membership lifecycle.
type Manager struct {
	cfg         *config.Config
	nodeName    string
	peerURL     string
	initialCluster string
	etcdDataDir    string
}

// NewManager creates a membership manager.
func NewManager(cfg *config.Config) *Manager {
	return &Manager{
		cfg:            cfg,
		nodeName:       cfg.EtcdName,
		peerURL:        cfg.PeerURL,
		initialCluster: cfg.InitialCluster,
		etcdDataDir:    cfg.EtcdDataDir,
	}
}

// Bootstrap ensures local etcd is running and part of the cluster.
// Returns the endpoints to use (always includes self first).
func (m *Manager) Bootstrap(ctx context.Context) error {
	if m.nodeName == "" || m.peerURL == "" {
		log.Printf("membership: --etcd-name and --peer-url not set, skipping bootstrap")
		return nil
	}

	// Already running?
	if m.isLocalHealthy(ctx) {
		log.Printf("membership: local etcd already healthy, skipping bootstrap")
		return nil
	}

	// Check if any peer has a healthy etcd cluster.
	for _, ep := range m.cfg.EtcdEndpoints {
		if m.isSelfEndpoint(ep) {
			continue
		}
		if m.isEndpointHealthy(ctx, ep) {
			log.Printf("membership: found existing etcd at %s, joining cluster", ep)
			return m.joinExisting(ctx, ep)
		}
	}

	// No peer found. If local etcd data exists from a prior run,
	// just start etcd (restart after crash/reboot).
	if m.hasExistingData() {
		log.Printf("membership: found existing etcd data, restarting")
		if err := m.writeEtcdConfig("existing", m.cfg.InitialCluster); err != nil {
			return fmt.Errorf("write etcd config (restart): %w", err)
		}
		if err := m.StartEtcd(); err != nil {
			return fmt.Errorf("start etcd (restart): %w", err)
		}
		if !m.waitForHealth(ctx) {
			return fmt.Errorf("local etcd (restart) did not become healthy within %v", healthTimeout)
		}
		log.Printf("membership: restarted from existing data")
		return nil
	}

	// No peer found and no local data — bootstrap new cluster.
	log.Printf("membership: no existing etcd found, bootstrapping new cluster")
	return m.bootstrapNew(ctx)
}

// hasExistingData returns true if etcd data directory has existing member data.
func (m *Manager) hasExistingData() bool {
	entries, _ := filepath.Glob(filepath.Join(m.etcdDataDir, "member", "snap", "db"))
	if len(entries) > 0 {
		return true
	}
	entries, _ = filepath.Glob(filepath.Join(m.etcdDataDir, "member", "wal", "*.wal"))
	return len(entries) > 0
}

// JoinExisting adds this node to an existing etcd cluster.
func (m *Manager) JoinExisting(ctx context.Context, seedEndpoint string) error {
	return m.joinExisting(ctx, seedEndpoint)
}

// Deregister removes this node from the etcd cluster before shutdown.
func (m *Manager) Deregister(ctx context.Context) error {
	if m.nodeName == "" {
		return nil
	}

	// Try to remove self from etcd membership.
	cli, err := m.connect(ctx, m.cfg.EtcdEndpoints)
	if err != nil {
		return fmt.Errorf("membership deregister connect: %w", err)
	}
	defer cli.Close()

	resp, err := cli.MemberList(ctx)
	if err != nil {
		return fmt.Errorf("member list for removal: %w", err)
	}

	selfID, found := m.findSelfInMembers(resp.Members)
	if !found {
		log.Printf("membership: self not found in member list, skipping removal")
		return nil
	}

	log.Printf("membership: removing self (ID=%x) from etcd cluster", selfID)
	_, err = cli.MemberRemove(ctx, selfID)
	if err != nil {
		return fmt.Errorf("member remove: %w", err)
	}

	log.Printf("membership: self removed from etcd cluster")
	return nil
}

// StartEtcd starts the local etcd systemd service.
func (m *Manager) StartEtcd() error {
	// Stop first to clear any auto-restart state from a previous failed run.
	exec.Command("systemctl", "stop", etcdService).Run()
	return exec.Command("systemctl", "start", etcdService).Run()
}

// StopEtcd stops the local etcd systemd service.
func (m *Manager) StopEtcd() error {
	return exec.Command("systemctl", "stop", etcdService).Run()
}

// --- internal ---

func (m *Manager) isSelfEndpoint(ep string) bool {
	// Match by etcd name, localhost, or peer URL (our IP:2380 → matches client URL IP:2379).
	if strings.Contains(ep, m.cfg.EtcdName) ||
		strings.HasPrefix(strings.TrimPrefix(strings.TrimPrefix(ep, "https://"), "http://"), "127.") ||
		strings.Contains(ep, "localhost") {
		return true
	}
	// Also match by IP: our peer URL's host should match the endpoint's host.
	peerHost := strings.TrimPrefix(strings.TrimPrefix(m.peerURL, "https://"), "http://")
	peerHost = strings.SplitN(peerHost, ":", 2)[0]
	epHost := strings.TrimPrefix(strings.TrimPrefix(ep, "https://"), "http://")
	epHost = strings.SplitN(epHost, ":", 2)[0]
	return peerHost == epHost
}

func (m *Manager) isLocalHealthy(ctx context.Context) bool {
	selfEP := m.selfEndpoint()
	if selfEP == "" {
		return false
	}
	return m.isEndpointHealthy(ctx, selfEP)
}

func (m *Manager) selfEndpoint() string {
	for _, ep := range m.cfg.EtcdEndpoints {
		if m.isSelfEndpoint(ep) {
			return ep
		}
	}
	// Build from peer URL (swap port 2380 → 2379)
	// Not needed if endpoints already include self.
	return ""
}

func (m *Manager) isEndpointHealthy(ctx context.Context, endpoint string) bool {
	cli, err := m.connect(ctx, []string{endpoint})
	if err != nil {
		return false
	}
	defer cli.Close()

	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err = cli.MemberList(cctx)
	return err == nil
}

func (m *Manager) connect(ctx context.Context, endpoints []string) (*clientv3.Client, error) {
	tlsCfg, err := m.buildTLS()
	if err != nil {
		return nil, fmt.Errorf("tls: %w", err)
	}

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: 10 * time.Second,
		TLS:         tlsCfg,
	})
	if err != nil {
		return nil, err
	}

	// Quick health check.
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_, err = cli.MemberList(cctx)
	if err != nil {
		cli.Close()
		return nil, err
	}

	return cli, nil
}

func (m *Manager) buildTLS() (*tls.Config, error) {
	if m.cfg.EtcdCAFile == "" || m.cfg.EtcdCertFile == "" || m.cfg.EtcdKeyFile == "" {
		return nil, fmt.Errorf("mTLS not configured")
	}

	ca, err := os.ReadFile(m.cfg.EtcdCAFile)
	if err != nil {
		return nil, fmt.Errorf("read CA: %w", err)
	}
	cert, err := tls.LoadX509KeyPair(m.cfg.EtcdCertFile, m.cfg.EtcdKeyFile)
	if err != nil {
		return nil, fmt.Errorf("load cert: %w", err)
	}

	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      pool,
		MinVersion:   tls.VersionTLS12,
	}, nil
}

func (m *Manager) bootstrapNew(ctx context.Context) error {
	// Always clean stale data from a previous failed run.
	os.RemoveAll(m.etcdDataDir)
	os.MkdirAll(m.etcdDataDir, 0700)

	// For a new cluster, initial cluster must include ONLY this node.
	// If we include peers that aren't up yet, etcd waits forever for quorum.
	// Peers join later via member add.
	initialCluster := fmt.Sprintf("%s=%s", m.nodeName, m.peerURL)

	if err := m.writeEtcdConfig("new", initialCluster); err != nil {
		return fmt.Errorf("write etcd config: %w", err)
	}
	if err := m.StartEtcd(); err != nil {
		return fmt.Errorf("start etcd: %w", err)
	}

	log.Printf("membership: waiting for local etcd to become healthy...")
	if !m.waitForHealth(ctx) {
		return fmt.Errorf("local etcd did not become healthy within %v", healthTimeout)
	}

	log.Printf("membership: new cluster bootstrapped with %s", m.nodeName)
	return nil
}

func (m *Manager) joinExisting(ctx context.Context, seedEndpoint string) error {
	log.Printf("membership: joinExisting seed=%s node=%s peer=%s", seedEndpoint, m.nodeName, m.peerURL)

	// Connect to the seed node.
	bootstrapCli, err := m.connect(ctx, []string{seedEndpoint})
	if err != nil {
		return fmt.Errorf("join: connect to seed %s: %w", seedEndpoint, err)
	}
	defer bootstrapCli.Close()

	// List current members to check if we're already a member.
	membersResp, err := bootstrapCli.MemberList(ctx)
	if err != nil {
		return fmt.Errorf("join: member list: %w", err)
	}
	log.Printf("membership: member list returned %d members", len(membersResp.Members))

	// Build the initial-cluster for the joining node.
	// Use the existing members + self.
	var parts []string
	found := false
	for _, member := range membersResp.Members {
		if member.Name == m.nodeName {
			found = true
		}
		for _, peerURL := range member.PeerURLs {
			parts = append(parts, fmt.Sprintf("%s=%s", member.Name, peerURL))
		}
	}

	if !found {
		// Add self as a new member.
		log.Printf("membership: adding self (%s) to cluster at %s", m.nodeName, seedEndpoint)
		addResp, err := bootstrapCli.MemberAdd(ctx, []string{m.peerURL})
		if err != nil {
			return fmt.Errorf("member add: %w", err)
		}
		log.Printf("membership: added, new member count=%d", len(addResp.Members))

		// Rebuild initial-cluster from the MemberAdd response.
		// The response includes all members (including the newly added one).
		// The new member may have an empty Name — replace with our nodeName.
		parts = nil
		for _, member := range addResp.Members {
			name := member.Name
			if name == "" {
				for _, pu := range member.PeerURLs {
					if pu == m.peerURL {
						name = m.nodeName
						break
					}
				}
			}
			for _, peerURL := range member.PeerURLs {
				parts = append(parts, fmt.Sprintf("%s=%s", name, peerURL))
			}
		}
	} else {
		log.Printf("membership: self (%s) already in member list, skipping MemberAdd", m.nodeName)
	}

	initialCluster := strings.Join(parts, ",")
	log.Printf("membership: initial cluster: %s", initialCluster)

	// Always clean stale data from a previous failed join.
	os.RemoveAll(m.etcdDataDir)
	os.MkdirAll(m.etcdDataDir, 0700)

	if err := m.writeEtcdConfig("existing", initialCluster); err != nil {
		return fmt.Errorf("write etcd config: %w", err)
	}
	if err := m.StartEtcd(); err != nil {
		return fmt.Errorf("start etcd: %w", err)
	}

	log.Printf("membership: waiting for local etcd to become healthy...")
	if !m.waitForHealth(ctx) {
		return fmt.Errorf("local etcd did not become healthy within %v", healthTimeout)
	}

	log.Printf("membership: joined existing cluster as %s (members=%d)", m.nodeName, strings.Count(initialCluster, "="))
	return nil
}

func (m *Manager) waitForHealth(ctx context.Context) bool {
	deadline := time.After(healthTimeout)
	ticker := time.NewTicker(healthInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return false
		case <-deadline:
			return false
		case <-ticker.C:
			if m.isLocalHealthy(ctx) {
				return true
			}
			log.Printf("membership: waiting for local etcd...")
		}
	}
}

func (m *Manager) writeEtcdConfig(state string, initialCluster string) error {
	os.MkdirAll(etcdConfigDir, 0755)
	os.MkdirAll(m.etcdDataDir, 0700)
	os.MkdirAll(etcdDropinDir, 0755)

	// Advertise URLs from the peer URL (swap 2380 → 2379 for client).
	clientURL := strings.Replace(m.peerURL, ":2380", ":2379", 1)

	// etcd server/peer certs (with IP SANs) are named by the etcd member name.
	serverCert := fmt.Sprintf("/etc/etcd/tls/server-%s.crt", m.nodeName)
	serverKey := fmt.Sprintf("/etc/etcd/tls/server-%s.key", m.nodeName)
	peerCert := fmt.Sprintf("/etc/etcd/tls/peer-%s.crt", m.nodeName)
	peerKey := fmt.Sprintf("/etc/etcd/tls/peer-%s.key", m.nodeName)
	// CA cert is shared between etcd and cluster-agent.
	caFile := m.cfg.EtcdCAFile

	// Write etcd command-line args file.
	args := fmt.Sprintf(
		"--name %s "+
			"--data-dir %s "+
			"--listen-client-urls https://0.0.0.0:2379 "+
			"--advertise-client-urls %s "+
			"--listen-peer-urls https://0.0.0.0:2380 "+
			"--initial-advertise-peer-urls %s "+
			"--initial-cluster %s "+
			"--initial-cluster-state %s "+
			"--initial-cluster-token %s "+
			"--client-cert-auth "+
			"--trusted-ca-file %s "+
			"--cert-file %s "+
			"--key-file %s "+
			"--peer-client-cert-auth "+
			"--peer-trusted-ca-file %s "+
			"--peer-cert-file %s "+
			"--peer-key-file %s",
		m.nodeName,
		m.etcdDataDir,
		clientURL,
		m.peerURL,
		initialCluster,
		state,
		m.cfg.ClusterName,
		caFile,
		serverCert,
		serverKey,
		caFile,
		peerCert,
		peerKey,
	)

	argsPath := filepath.Join(etcdConfigDir, "etcd.args")
	if err := os.WriteFile(argsPath, []byte(args), 0644); err != nil {
		return fmt.Errorf("write %s: %w", argsPath, err)
	}

	// Write systemd drop-in that uses the args file.
	// Use single quotes so $(cat ...) is passed literally to /bin/sh
	// (systemd does not interpret single quotes, but sh does).
	dropin := fmt.Sprintf(`# Generated by cluster-agent membership manager.
[Service]
ExecStart=
ExecStart=/bin/sh -c 'exec /usr/local/bin/etcd $(cat %s)'
Restart=always
`, argsPath)

	dropinPath := filepath.Join(etcdDropinDir, "qattach.conf")
	if err := os.WriteFile(dropinPath, []byte(dropin), 0644); err != nil {
		return fmt.Errorf("write %s: %w", dropinPath, err)
	}

	// Reload systemd so the drop-in takes effect.
	exec.Command("systemctl", "daemon-reload").Run()

	log.Printf("membership: wrote etcd config to %s (state=%s, members=%d)",
		argsPath, state, strings.Count(initialCluster, "="))
	return nil
}

func (m *Manager) findSelfInMembers(members []*pb.Member) (uint64, bool) {
	for _, member := range members {
		for _, peerURL := range member.PeerURLs {
			if peerURL == m.peerURL {
				return member.ID, true
			}
		}
	}
	return 0, false
}

// ParseClusterMember parses a single "name=https://ip:port" entry.
func ParseClusterMember(entry string) (name string, url string) {
	parts := strings.SplitN(entry, "=", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}
