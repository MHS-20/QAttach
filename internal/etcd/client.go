package etcd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/client/v3/concurrency"

	"github.com/polarity/qattach/internal/config"
	"github.com/polarity/qattach/pkg/protocol"
)

// Client wraps etcd client with session management.
type Client struct {
	cli  *clientv3.Client
	sess *concurrency.Session
	cfg  *config.Config
}

// New creates a new etcd client with mTLS and session lease.
func New(ctx context.Context, cfg *config.Config) (*Client, error) {
	tlsCfg, err := buildTLSConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("tls config: %w", err)
	}

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   cfg.EtcdEndpoints,
		DialTimeout: 10 * time.Second,
		TLS:         tlsCfg,
	})
	if err != nil {
		return nil, fmt.Errorf("etcd connect: %w", err)
	}

	// Verify connectivity
	statusCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := cli.Status(statusCtx, cli.Endpoints()[0]); err != nil {
		cli.Close()
		return nil, fmt.Errorf("etcd status check: %w", err)
	}

	// Create session lease with keepalive
	sess, err := concurrency.NewSession(cli,
		concurrency.WithTTL(int(cfg.SessionTTL.Seconds())),
	)
	if err != nil {
		cli.Close()
		return nil, fmt.Errorf("etcd session: %w", err)
	}

	return &Client{
		cli:  cli,
		sess: sess,
		cfg:  cfg,
	}, nil
}

// RegisterNode atomically writes /cluster/members/{node_id} attached to session lease.
func (c *Client) RegisterNode(ctx context.Context, nodeID, instanceID, ip, az string) error {
	val := fmt.Sprintf(`{"instance_id":"%s","ip":"%s","az":"%s"}`, instanceID, ip, az)
	key := protocol.PrefixMembers + nodeID

	_, err := c.cli.Put(ctx, key, val, clientv3.WithLease(c.sess.Lease()))
	return err
}

// DeregisterNode removes the member key and revokes the session lease.
func (c *Client) DeregisterNode(ctx context.Context, nodeID string) error {
	key := protocol.PrefixMembers + nodeID
	if _, err := c.cli.Delete(ctx, key); err != nil {
		return err
	}
	return c.sess.Close()
}

// AcquireLock attempts a CAS transaction to acquire a lock key.
// Returns (granted, etcd_revision, error).
func (c *Client) AcquireLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID, mode string) (bool, int64, error) {
	key := fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
	val := fmt.Sprintf(`{"owner_node_id":"%s","mode":"%s"}`, nodeID, mode)

	txnResp, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(key), "=", 0)).
		Then(clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease()))).
		Else(clientv3.OpGet(key)).
		Commit()
	if err != nil {
		return false, 0, fmt.Errorf("acquire lock txn: %w", err)
	}

	if !txnResp.Succeeded {
		return false, 0, nil
	}

	return true, txnResp.Header.Revision, nil
}

// ReleaseLock deletes the lock key from etcd.
func (c *Client) ReleaseLock(ctx context.Context, lockType uint32, lockNumber uint64) error {
	key := fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
	_, err := c.cli.Delete(ctx, key)
	return err
}

// WatchMemberDeletions watches for session lease expirations on member keys.
func (c *Client) WatchMemberDeletions(ctx context.Context) clientv3.WatchChan {
	return c.cli.Watch(ctx,
		protocol.PrefixMembers,
		clientv3.WithPrefix(),
		clientv3.WithPrevKV(),
	)
}

// WatchLockKey watches a specific lock key for changes (BAST coordination).
func (c *Client) WatchLockKey(ctx context.Context, lockType uint32, lockNumber uint64) clientv3.WatchChan {
	key := fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
	return c.cli.Watch(ctx, key)
}

// CASFencing attempts to win the fencing race for a failed node.
// Returns true if this node won the race.
func (c *Client) CASFencing(ctx context.Context, failedNodeID, localNodeID string) (bool, error) {
	key := protocol.PrefixFencing + failedNodeID

	lease, err := c.cli.Grant(ctx, int64(c.cfg.FencingLeaseTTL.Seconds()))
	if err != nil {
		return false, fmt.Errorf("fencing lease grant: %w", err)
	}

	txnResp, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(key), "=", 0)).
		Then(clientv3.OpPut(key, localNodeID, clientv3.WithLease(lease.ID))).
		Commit()
	if err != nil {
		return false, fmt.Errorf("fencing cas: %w", err)
	}

	return txnResp.Succeeded, nil
}

// IncrementEpoch atomically increments the cluster epoch after a crash.
func (c *Client) IncrementEpoch(ctx context.Context) (int64, error) {
	resp, err := c.cli.Put(ctx, protocol.KeyEpoch, "", clientv3.WithIgnoreValue())
	if err != nil {
		return 0, err
	}
	return resp.Header.Revision, nil
}

// GetLockRevision returns the current etcd revision of a lock key.
func (c *Client) GetLockRevision(ctx context.Context, lockType uint32, lockNumber uint64) (int64, error) {
	key := fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
	resp, err := c.cli.Get(ctx, key)
	if err != nil {
		return 0, err
	}
	if resp.Count == 0 {
		return 0, nil
	}
	return resp.Kvs[0].ModRevision, nil
}

// WatchPrefix watches a prefix for changes.
func (c *Client) WatchPrefix(ctx context.Context, prefix string) clientv3.WatchChan {
	return c.cli.Watch(ctx, prefix, clientv3.WithPrefix())
}

// Close shuts down the etcd session and client.
func (c *Client) Close() error {
	if c.sess != nil {
		c.sess.Close()
	}
	return c.cli.Close()
}

// Lease returns the current session lease ID.
func (c *Client) Lease() clientv3.LeaseID {
	return c.sess.Lease()
}

func buildTLSConfig(cfg *config.Config) (*tls.Config, error) {
	if cfg.EtcdCAFile == "" && cfg.EtcdCertFile == "" {
		return nil, nil // no TLS
	}

	caCert, err := os.ReadFile(cfg.EtcdCAFile)
	if err != nil {
		return nil, fmt.Errorf("read ca cert: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to parse CA certificate")
	}

	cert, err := tls.LoadX509KeyPair(cfg.EtcdCertFile, cfg.EtcdKeyFile)
	if err != nil {
		return nil, fmt.Errorf("load client cert/key: %w", err)
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
		MinVersion:   tls.VersionTLS12,
	}, nil
}
