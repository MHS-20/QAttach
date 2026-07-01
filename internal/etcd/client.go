package etcd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
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

	statusCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := cli.Status(statusCtx, cli.Endpoints()[0]); err != nil {
		cli.Close()
		return nil, fmt.Errorf("etcd status check: %w", err)
	}

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

// RegisterNode atomically writes /cluster/members/{node_id} with session lease.
func (c *Client) RegisterNode(ctx context.Context, nodeID, instanceID, ip, az string) error {
	val := fmt.Sprintf(`{"instance_id":"%s","ip":"%s","az":"%s"}`, instanceID, ip, az)
	key := protocol.PrefixMembers + nodeID
	_, err := c.cli.Put(ctx, key, val, clientv3.WithLease(c.sess.Lease()))
	return err
}

// AssignJournal atomically claims a journal slot via CAS.
func (c *Client) AssignJournal(ctx context.Context, nodeID string, max int) (int32, error) {
	for jid := int32(0); jid < int32(max); jid++ {
		key := fmt.Sprintf("%s%d", protocol.PrefixJournal, jid)
		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", 0)).
			Then(clientv3.OpPut(key, nodeID, clientv3.WithLease(c.sess.Lease()))).
			Commit()
		if err != nil {
			return -1, fmt.Errorf("journal %d CAS: %w", jid, err)
		}
		if txnResp.Succeeded {
			return jid, nil
		}
	}
	return -1, nil
}

// DeregisterNode removes the member key and revokes the session lease.
func (c *Client) DeregisterNode(ctx context.Context, nodeID string) error {
	key := protocol.PrefixMembers + nodeID
	if _, err := c.cli.Delete(ctx, key); err != nil {
		return err
	}
	return c.sess.Close()
}

// ---- lock key helpers ----

func lockKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d", protocol.PrefixLocks, lockType, lockNumber)
}

// lockEntry is a single holder in the holders array.
type lockEntry struct {
	Node string `json:"node"`
	Mode string `json:"mode"` // EX, PR, CW
}

func parseHolders(raw []byte) []lockEntry {
	var h []lockEntry
	if len(raw) == 0 {
		return nil
	}
	json.Unmarshal(raw, &h)
	return h
}

func marshalHolders(h []lockEntry) string {
	b, _ := json.Marshal(h)
	return string(b)
}

// firstHolderInfo returns (mode, nodeID) of the first holder, or ("", "").
func firstHolderInfo(raw []byte) (string, string) {
	h := parseHolders(raw)
	if len(h) == 0 {
		return "", ""
	}
	return h[0].Mode, h[0].Node
}

// ---- lock operations ----

// AcquireLock acquires a lock using a single-key holder-array model.
//
// Key:  /locks/glock/{type}/{number}
// Value: [{"node":"A","mode":"EX"},{"node":"B","mode":"PR"}]
//
// EX mode: CAS that key does not exist, then Put with one EX holder.
// SH mode: read holders, check no EX exists, append SH entry via optimistic lock.
//
// Returns (granted, revision, first_holder_mode, first_holder_node, error).
func (c *Client) AcquireLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID, mode string) (bool, int64, string, string, error) {
	key := lockKey(lockType, lockNumber)

	if mode == "EX" {
		val := marshalHolders([]lockEntry{{Node: nodeID, Mode: mode}})
		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", 0)).
			Then(clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease()))).
			Else(clientv3.OpGet(key)).
			Commit()
		if err != nil {
			return false, 0, "", "", fmt.Errorf("acquire EX txn: %w", err)
		}
		if !txnResp.Succeeded {
			hm, hn := "", ""
			if len(txnResp.Responses) > 0 {
				for _, ev := range txnResp.Responses[0].GetResponseRange().Kvs {
					hm, hn = firstHolderInfo(ev.Value)
					break
				}
			}
			return false, 0, hm, hn, nil
		}
		return true, txnResp.Header.Revision, "", "", nil
	}

	// SH mode: append to holders array if no EX holder exists.
	getResp, err := c.cli.Get(ctx, key)
	if err != nil {
		return false, 0, "", "", fmt.Errorf("get before SH: %w", err)
	}

	holders := []lockEntry{}
	ver := int64(0)
	if len(getResp.Kvs) > 0 {
		ver = getResp.Kvs[0].Version
		holders = parseHolders(getResp.Kvs[0].Value)
		for _, h := range holders {
			if h.Mode == "EX" {
				return false, 0, h.Mode, h.Node, nil
			}
		}
	}

	holders = append(holders, lockEntry{Node: nodeID, Mode: mode})
	val := marshalHolders(holders)
	txnResp, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(key), "=", ver)).
		Then(clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease()))).
		Else(clientv3.OpGet(key)).
		Commit()
	if err != nil {
		return false, 0, "", "", fmt.Errorf("acquire SH txn: %w", err)
	}
	if !txnResp.Succeeded {
		hm, hn := "", ""
		if len(txnResp.Responses) > 0 {
			for _, ev := range txnResp.Responses[0].GetResponseRange().Kvs {
				hm, hn = firstHolderInfo(ev.Value)
				break
			}
		}
		return false, 0, hm, hn, nil
	}
	return true, txnResp.Header.Revision, "", "", nil
}

// ReleaseLock removes this node's entry from the holders array.
// If the array becomes empty, the key is deleted.
func (c *Client) ReleaseLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	key := lockKey(lockType, lockNumber)
	getResp, err := c.cli.Get(ctx, key)
	if err != nil {
		return err
	}
	if len(getResp.Kvs) == 0 {
		return nil
	}

	ver := getResp.Kvs[0].Version
	holders := parseHolders(getResp.Kvs[0].Value)

	filtered := make([]lockEntry, 0, len(holders))
	for _, h := range holders {
		if h.Node != nodeID {
			filtered = append(filtered, h)
		}
	}

	if len(filtered) == 0 {
		c.cli.Delete(ctx, key)
		return nil
	}

	_, err = c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(key), "=", ver)).
		Then(clientv3.OpPut(key, marshalHolders(filtered),
			clientv3.WithLease(c.sess.Lease()))).
		Commit()
	return err
}

// ---- watches ----

func (c *Client) WatchMemberDeletions(ctx context.Context) clientv3.WatchChan {
	return c.cli.Watch(ctx,
		protocol.PrefixMembers,
		clientv3.WithPrefix(),
		clientv3.WithPrevKV(),
	)
}

func (c *Client) WatchLockKey(ctx context.Context, lockType uint32, lockNumber uint64) clientv3.WatchChan {
	return c.cli.Watch(ctx, lockKey(lockType, lockNumber))
}

// ---- bast / handoff ----

func bastKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d", protocol.PrefixBast, lockType, lockNumber)
}

func (c *Client) RequestBast(ctx context.Context, lockType uint32, lockNumber uint64, targetMode uint32, waiterID string) error {
	key := bastKey(lockType, lockNumber)
	val := fmt.Sprintf("%d,%s", targetMode, waiterID)
	lease, err := c.cli.Grant(ctx, int64(c.cfg.SessionTTL.Seconds()))
	if err != nil {
		return fmt.Errorf("bast lease grant: %w", err)
	}
	_, err = c.cli.Put(ctx, key, val, clientv3.WithLease(lease.ID))
	return err
}

func handoffKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d/next", protocol.PrefixHandoff, lockType, lockNumber)
}

// HandoffRelease atomically deletes the lock key and writes a handoff
// reservation for the waiter.
func (c *Client) HandoffRelease(ctx context.Context, lockType uint32, lockNumber uint64, waiterID string) error {
	lk := lockKey(lockType, lockNumber)
	hk := handoffKey(lockType, lockNumber)
	lease, err := c.cli.Grant(ctx, int64(protocol.HandoffTTL))
	if err != nil {
		return fmt.Errorf("handoff lease: %w", err)
	}
	_, err = c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(lk), ">", 0)).
		Then(clientv3.OpDelete(lk), clientv3.OpPut(hk, waiterID, clientv3.WithLease(lease.ID))).
		Commit()
	return err
}

func (c *Client) CheckHandoff(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) (bool, error) {
	resp, err := c.cli.Get(ctx, handoffKey(lockType, lockNumber))
	if err != nil {
		return false, err
	}
	if len(resp.Kvs) == 0 {
		return false, nil
	}
	return string(resp.Kvs[0].Value) == nodeID, nil
}

// HasWaiter returns true if a bast key exists for this lock,
// meaning another node is waiting and this holder should yield.
func (c *Client) HasWaiter(ctx context.Context, lockType uint32, lockNumber uint64) bool {
	resp, err := c.cli.Get(ctx, bastKey(lockType, lockNumber))
	if err != nil || len(resp.Kvs) == 0 {
		return false
	}
	return true
}

func (c *Client) DeleteHandoff(ctx context.Context, lockType uint32, lockNumber uint64) error {
	_, err := c.cli.Delete(ctx, handoffKey(lockType, lockNumber))
	return err
}

func (c *Client) DeleteBastRequest(ctx context.Context, lockType uint32, lockNumber uint64) error {
	_, err := c.cli.Delete(ctx, bastKey(lockType, lockNumber))
	return err
}

func (c *Client) WatchLockBast(ctx context.Context, lockType uint32, lockNumber uint64) clientv3.WatchChan {
	return c.cli.Watch(ctx, bastKey(lockType, lockNumber))
}

// ---- fencing ----

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

func (c *Client) IncrementEpoch(ctx context.Context) (int64, error) {
	resp, err := c.cli.Put(ctx, protocol.KeyEpoch, "", clientv3.WithIgnoreValue())
	if err != nil {
		return 0, err
	}
	return resp.Header.Revision, nil
}

func (c *Client) GetLockRevision(ctx context.Context, lockType uint32, lockNumber uint64) (int64, error) {
	key := lockKey(lockType, lockNumber)
	resp, err := c.cli.Get(ctx, key)
	if err != nil {
		return 0, err
	}
	if resp.Count == 0 {
		return 0, nil
	}
	return resp.Kvs[0].ModRevision, nil
}

func (c *Client) WatchPrefix(ctx context.Context, prefix string) clientv3.WatchChan {
	return c.cli.Watch(ctx, prefix, clientv3.WithPrefix())
}

func (c *Client) MarkFencingComplete(ctx context.Context, failedNodeID, result string) error {
	key := protocol.PrefixFencing + failedNodeID
	_, err := c.cli.Put(ctx, key, result)
	return err
}

func (c *Client) WatchFencingKey(ctx context.Context, failedNodeID string) clientv3.WatchChan {
	key := protocol.PrefixFencing + failedNodeID
	return c.cli.Watch(ctx, key)
}

func (c *Client) Close() error {
	if c.sess != nil {
		c.sess.Close()
	}
	return c.cli.Close()
}

func (c *Client) Lease() clientv3.LeaseID {
	return c.sess.Lease()
}

func buildTLSConfig(cfg *config.Config) (*tls.Config, error) {
	if cfg.EtcdCAFile == "" && cfg.EtcdCertFile == "" {
		return nil, nil
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
