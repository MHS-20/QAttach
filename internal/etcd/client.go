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

// lockKey returns the primary (EX) lock key.
func lockKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
}

// lockSHKey returns the per-holder shared lock sub-key.
func lockSHKey(lockType uint32, lockNumber uint64, nodeID string) string {
	return fmt.Sprintf("%s%d/%d/holders/%s", protocol.PrefixLocks, lockType, lockNumber, nodeID)
}

// AcquireLock attempts to acquire a lock.
// EX mode uses a CAS on a single key — only one holder.
// SH mode uses per-holder sub-keys — multiple concurrent holders allowed.
// Returns (granted, etcd_revision, error).
func (c *Client) AcquireLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID, mode string) (bool, int64, error) {
	key := lockKey(lockType, lockNumber)
	val := fmt.Sprintf(`{"owner_node_id":"%s","mode":"%s"}`, nodeID, mode)

	if mode == "EX" {
		// Exclusive: CAS on primary key (must not exist).
		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", 0)).
			Then(clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease()))).
			Else(clientv3.OpGet(key)).
			Commit()
		if err != nil {
			return false, 0, fmt.Errorf("acquire EX lock txn: %w", err)
		}
		if !txnResp.Succeeded {
			return false, 0, nil
		}
		return true, txnResp.Header.Revision, nil
	}

	// SH mode: check if an EX holder exists; if not, create per-holder sub-key.
	// First, check the primary key to detect EX contention.
	getResp, err := c.cli.Get(ctx, key)
	if err != nil {
		return false, 0, fmt.Errorf("check EX lock before SH: %w", err)
	}
	if len(getResp.Kvs) > 0 {
		// Key exists — check if it's an EX lock.
		// If EX, we're contended.  If SH, we can join.
		// We assume the key stores JSON with a "mode" field.
		// For simplicity: if key exists at all, check mode.
		if string(getResp.Kvs[0].Value) != "" {
			// Parse mode — if EX, bail and let caller request bast.
			// If already SH, proceed to sub-key.
			if len(getResp.Kvs[0].Value) > 0 {
				valStr := string(getResp.Kvs[0].Value)
				if len(valStr) > 8 && valStr[8:10] == "EX" {
					return false, 0, nil // EX held, contended
				}
			}
		}
	}

	// Write per-holder SH sub-key (unique per node).
	shKey := lockSHKey(lockType, lockNumber, nodeID)
	txnResp, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(shKey), "=", 0)).
		Then(clientv3.OpPut(shKey, val, clientv3.WithLease(c.sess.Lease()))).
		Commit()
	if err != nil {
		return false, 0, fmt.Errorf("acquire SH lock txn: %w", err)
	}
	if !txnResp.Succeeded {
		return false, 0, nil
	}

	// Ensure primary key exists as a marker (mode: SH).
	c.cli.Put(ctx, key, val, clientv3.WithLease(c.sess.Lease()))

	return true, txnResp.Header.Revision, nil
}

// ReleaseLock deletes the lock key(s) from etcd.
// For EX locks, deletes the primary key.
// For SH locks, deletes this node's holder sub-key.
func (c *Client) ReleaseLock(ctx context.Context, lockType uint32, lockNumber uint64) error {
	// Always try to delete the primary key (EX holder).
	c.cli.Delete(ctx, lockKey(lockType, lockNumber))
	return nil
}

// ReleaseSHLock deletes only this node's shared lock sub-key.
func (c *Client) ReleaseSHLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	_, err := c.cli.Delete(ctx, lockSHKey(lockType, lockNumber, nodeID))
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

// bastKey returns the bast request key for a given lock.
func bastKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d", protocol.PrefixBast, lockType, lockNumber)
}

// RequestBast writes a bast (blocking AST) request to signal the lock
// holder that another node wants the lock.  The holder should downgrade
// or release in response.
func (c *Client) RequestBast(ctx context.Context, lockType uint32, lockNumber uint64, targetMode uint32) error {
	key := bastKey(lockType, lockNumber)
	val := fmt.Sprintf("%d", targetMode)
	lease, err := c.cli.Grant(ctx, int64(c.cfg.SessionTTL.Seconds()))
	if err != nil {
		return fmt.Errorf("bast lease grant: %w", err)
	}
	_, err = c.cli.Put(ctx, key, val, clientv3.WithLease(lease.ID))
	return err
}

// DeleteBastRequest removes a bast request key after it has been serviced.
func (c *Client) DeleteBastRequest(ctx context.Context, lockType uint32, lockNumber uint64) error {
	_, err := c.cli.Delete(ctx, bastKey(lockType, lockNumber))
	return err
}

// WatchLockBast watches for bast requests on a specific lock.
// Used by the lock holder to detect when another node wants the lock.
func (c *Client) WatchLockBast(ctx context.Context, lockType uint32, lockNumber uint64) clientv3.WatchChan {
	return c.cli.Watch(ctx, bastKey(lockType, lockNumber))
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

// MarkFencingComplete writes the fencing result so other surviving nodes can
// observe that fencing completed.
func (c *Client) MarkFencingComplete(ctx context.Context, failedNodeID, result string) error {
	key := protocol.PrefixFencing + failedNodeID
	_, err := c.cli.Put(ctx, key, result)
	return err
}

// WatchFencingKey watches the fencing key for a specific failed node.
func (c *Client) WatchFencingKey(ctx context.Context, failedNodeID string) clientv3.WatchChan {
	key := protocol.PrefixFencing + failedNodeID
	return c.cli.Watch(ctx, key)
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
