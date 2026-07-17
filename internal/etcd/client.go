package etcd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"strings"
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
	tlsCfg, err := BuildTLSConfig(cfg)
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

// isHolder returns true if nodeID appears in the holders array.
func isHolder(raw []byte, nodeID string) bool {
	for _, h := range parseHolders(raw) {
		if h.Node == nodeID {
			return true
		}
	}
	return false
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

// modesConflict returns true if two lock modes conflict.
func modesConflict(a, b string) bool {
	if a == b {
		return false
	}
	if a == "EX" || b == "EX" {
		return true
	}
	return false
}

// ConvertLock converts an already-held lock to a new mode without releasing.
// Updates our entry in the holders array. If no conflicting holders remain
// after the update, returns granted=true. Otherwise returns granted=false
// (caller must watch for other holders to release).
// Returns an error if another node already holds EX (caller should release
// and retry as a new request).
func (c *Client) ConvertLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID, newMode string) (granted bool, rev int64, err error) {
	key := lockKey(lockType, lockNumber)

	for {
		getResp, err := c.cli.Get(ctx, key)
		if err != nil {
			return false, 0, fmt.Errorf("convert get: %w", err)
		}
		if len(getResp.Kvs) == 0 {
			return false, 0, fmt.Errorf("convert: lock not held")
		}

		ver := getResp.Kvs[0].Version
		holders := parseHolders(getResp.Kvs[0].Value)

		ourIdx := -1
		for i, h := range holders {
			if h.Node == nodeID {
				ourIdx = i
				break
			}
		}
		if ourIdx < 0 {
			return false, 0, fmt.Errorf("convert: self not in holders")
		}

		if holders[ourIdx].Mode == newMode {
			for i, h := range holders {
				if i == ourIdx {
					continue
				}
				if modesConflict(newMode, h.Mode) {
					return false, 0, nil
				}
			}
			return true, getResp.Kvs[0].ModRevision, nil
		}

		if newMode == "EX" {
			for i, h := range holders {
				if i == ourIdx {
					continue
				}
				if h.Mode == "EX" {
					return false, 0, fmt.Errorf("convert: another node holds EX")
				}
			}
		}

		newHolders := make([]lockEntry, len(holders))
		copy(newHolders, holders)
		newHolders[ourIdx].Mode = newMode

		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", ver)).
			Then(clientv3.OpPut(key, marshalHolders(newHolders),
				clientv3.WithLease(c.sess.Lease()))).
			Commit()
		if err != nil {
			return false, 0, fmt.Errorf("convert txn: %w", err)
		}
		if !txnResp.Succeeded {
			continue
		}

		for i, h := range newHolders {
			if i == ourIdx {
				continue
			}
			if modesConflict(newMode, h.Mode) {
				return false, 0, nil
			}
		}
		return true, txnResp.Header.Revision, nil
	}
}

// ProcessLock handles a lock request atomically in a single etcd Txn.
// Replaces the previous multi-step ConvertLock+AcquireLock+watch flow.
//
// The Txn inspects the current key state and decides:
//   - GRANTED: appended/updated our entry, no conflicts remain
//   - WAIT:    conflicts exist, we're queued as a waiter
//   - ERROR:   something went wrong
//
// The caller must:
//   - On GRANTED: send GRANT to kernel, track the held lock
//   - On WAIT:    send WAIT to kernel, start retry goroutine
func (c *Client) ProcessLock(ctx context.Context, lockType uint32, lockNumber uint64,
	nodeID, mode string) (granted bool, rev int64, err error) {
	key := lockKey(lockType, lockNumber)

	for {
		getResp, err := c.cli.Get(ctx, key)
		if err != nil {
			return false, 0, fmt.Errorf("process get: %w", err)
		}

		// Key doesn't exist — straightforward grant.
		if len(getResp.Kvs) == 0 {
			val := marshalHolders([]lockEntry{{Node: nodeID, Mode: mode}})
			txnResp, err := c.cli.Txn(ctx).
				If(clientv3.Compare(clientv3.Version(key), "=", 0)).
				Then(clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease()))).
				Commit()
			if err != nil {
				return false, 0, fmt.Errorf("process empty txn: %w", err)
			}
			if !txnResp.Succeeded {
				continue // key was created between Get and Txn — retry
			}
			return true, txnResp.Header.Revision, nil
		}

		ver := getResp.Kvs[0].Version
		holders := parseHolders(getResp.Kvs[0].Value)

		ourIdx := -1
		for i, h := range holders {
			if h.Node == nodeID {
				ourIdx = i
				break
			}
		}

		if ourIdx >= 0 {
			// ---- Self-contention: we're already a holder ----
			if holders[ourIdx].Mode == mode {
				// Already at target mode — just check conflicts.
				for i, h := range holders {
					if i == ourIdx {
						continue
					}
					if modesConflict(mode, h.Mode) {
						return false, 0, nil
					}
				}
				return true, getResp.Kvs[0].ModRevision, nil
			}

			// Mode change.
			if mode == "EX" {
				for i, h := range holders {
					if i == ourIdx {
						continue
					}
					if h.Mode == "EX" {
						// Another node already has EX — remove
						// our entry and become a waiter.
						newH := make([]lockEntry, 0, len(holders)-1)
						for j, h2 := range holders {
							if j != ourIdx {
								newH = append(newH, h2)
							}
						}
						txnResp, err := c.cli.Txn(ctx).
							If(clientv3.Compare(clientv3.Version(key), "=", ver)).
							Then(clientv3.OpPut(key, marshalHolders(newH),
								clientv3.WithLease(c.sess.Lease()))).
							Commit()
						if err != nil {
							return false, 0, fmt.Errorf("process remove-self txn: %w", err)
						}
						if !txnResp.Succeeded {
							continue
						}
						return false, 0, nil
					}
				}
			}

			// Update our mode.
			newHolders := make([]lockEntry, len(holders))
			copy(newHolders, holders)
			newHolders[ourIdx].Mode = mode

			txnResp, err := c.cli.Txn(ctx).
				If(clientv3.Compare(clientv3.Version(key), "=", ver)).
				Then(clientv3.OpPut(key, marshalHolders(newHolders),
					clientv3.WithLease(c.sess.Lease()))).
				Commit()
			if err != nil {
				return false, 0, fmt.Errorf("process update txn: %w", err)
			}
			if !txnResp.Succeeded {
				continue
			}

			for i, h := range newHolders {
				if i == ourIdx {
					continue
				}
				if modesConflict(mode, h.Mode) {
					return false, 0, nil
				}
			}
			return true, txnResp.Header.Revision, nil
		}

		// ---- Fresh acquisition: we're not a holder ----
		if mode == "EX" {
			// Key exists with holders — can't get EX.
			return false, 0, nil
		}

		// PR mode — check for EX holder.
		for _, h := range holders {
			if h.Mode == "EX" {
				return false, 0, nil
			}
		}

		// Append our PR entry.
		newHolders := append(holders, lockEntry{Node: nodeID, Mode: mode})
		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", ver)).
			Then(clientv3.OpPut(key, marshalHolders(newHolders),
				clientv3.WithLease(c.sess.Lease()))).
			Commit()
		if err != nil {
			return false, 0, fmt.Errorf("process append txn: %w", err)
		}
		if !txnResp.Succeeded {
			continue
		}
		return true, txnResp.Header.Revision, nil
	}
}

// AmIHolder checks if nodeID is among the current holders of this lock.
func (c *Client) AmIHolder(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) bool {
	key := lockKey(lockType, lockNumber)
	getResp, err := c.cli.Get(ctx, key)
	if err != nil || len(getResp.Kvs) == 0 {
		return false
	}
	return isHolder(getResp.Kvs[0].Value, nodeID)
}

// ReleaseLock removes this node's entry from the holders array.
// If the array becomes empty, the key is deleted.
// Retries on CAS version mismatch (concurrent multi-holder release).
func (c *Client) ReleaseLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	key := lockKey(lockType, lockNumber)

	for {
		getResp, err := c.cli.Get(ctx, key)
		if err != nil {
			return err
		}
		if len(getResp.Kvs) == 0 {
			return nil
		}

		ver := getResp.Kvs[0].Version
		holders := parseHolders(getResp.Kvs[0].Value)
		if len(holders) == 0 {
			return nil
		}

		filtered := make([]lockEntry, 0, len(holders))
		for _, h := range holders {
			if h.Node != nodeID {
				filtered = append(filtered, h)
			}
		}

		var txnResp *clientv3.TxnResponse
		if len(filtered) == 0 {
			txnResp, err = c.cli.Txn(ctx).
				If(clientv3.Compare(clientv3.Version(key), "=", ver)).
				Then(clientv3.OpDelete(key)).
				Commit()
		} else {
			txnResp, err = c.cli.Txn(ctx).
				If(clientv3.Compare(clientv3.Version(key), "=", ver)).
				Then(clientv3.OpPut(key, marshalHolders(filtered),
					clientv3.WithLease(c.sess.Lease()))).
				Commit()
		}
		if err != nil {
			return err
		}
		if txnResp.Succeeded {
			return nil
		}
	}
}

// ---- watches ----

func (c *Client) WatchMemberDeletions(ctx context.Context) clientv3.WatchChan {
	return c.cli.Watch(ctx,
		protocol.PrefixMembers,
		clientv3.WithPrefix(),
		clientv3.WithPrevKV(),
	)
}


// ---- wait queue ----

// AddWaiter registers this node as a waiter for a lock.
func (c *Client) AddWaiter(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	key := waitKey(lockType, lockNumber, nodeID)
	_, err := c.cli.Put(ctx, key, nodeID, clientv3.WithLease(c.sess.Lease()))
	return err
}

// RemoveWaiter removes this node's waiter registration.
func (c *Client) RemoveWaiter(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	_, err := c.cli.Delete(ctx, waitKey(lockType, lockNumber, nodeID))
	return err
}

// GetWaiters returns waiter node IDs sorted by CreateRevision (FIFO order).
func (c *Client) GetWaiters(ctx context.Context, lockType uint32, lockNumber uint64) ([]string, error) {
	resp, err := c.cli.Get(ctx, waitPrefix(lockType, lockNumber),
		clientv3.WithPrefix(),
		clientv3.WithSort(clientv3.SortByCreateRevision, clientv3.SortAscend))
	if err != nil {
		return nil, err
	}
	waiters := make([]string, 0, len(resp.Kvs))
	for _, kv := range resp.Kvs {
		waiters = append(waiters, string(kv.Value))
	}
	return waiters, nil
}

func handoffKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d/next", protocol.PrefixWait, lockType, lockNumber)
}

// HandoffRelease atomically deletes the lock key and writes a handoff
// reservation for the next waiter.  Returns the handoff target nodeID.
func (c *Client) HandoffRelease(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) (string, error) {
	waiters, err := c.GetWaiters(ctx, lockType, lockNumber)
	if err != nil || len(waiters) == 0 {
		return "", err
	}
	lk := lockKey(lockType, lockNumber)
	hk := handoffKey(lockType, lockNumber)
	target := waiters[0]
	_, err = c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(lk), ">", 0)).
		Then(clientv3.OpDelete(lk),
			clientv3.OpPut(hk, target, clientv3.WithLease(c.sess.Lease()))).
		Commit()
	return target, err
}

// CheckHandoff returns true if there's a handoff marker for this node.
func (c *Client) CheckHandoff(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) (bool, error) {
	resp, err := c.cli.Get(ctx, handoffKey(lockType, lockNumber))
	if err != nil || len(resp.Kvs) == 0 {
		return false, err
	}
	return string(resp.Kvs[0].Value) == nodeID, nil
}

// IsFirstWaiter returns true if this node is the oldest waiter.
func (c *Client) IsFirstWaiter(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) (bool, error) {
	waiters, err := c.GetWaiters(ctx, lockType, lockNumber)
	if err != nil {
		return false, err
	}
	if len(waiters) == 0 {
		return false, nil
	}
	return waiters[0] == nodeID, nil
}

// ---- bast / handoff ----

func bastKey(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d", protocol.PrefixBast, lockType, lockNumber)
}

func waitKey(lockType uint32, lockNumber uint64, nodeID string) string {
	return fmt.Sprintf("%s%d/%d/wait/%s", protocol.PrefixWait, lockType, lockNumber, nodeID)
}

func waitPrefix(lockType uint32, lockNumber uint64) string {
	return fmt.Sprintf("%s%d/%d/wait/", protocol.PrefixWait, lockType, lockNumber)
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

// HasWaiter returns true and the waiter's nodeID if a bast key exists.
func (c *Client) HasWaiter(ctx context.Context, lockType uint32, lockNumber uint64) (bool, string) {
	resp, err := c.cli.Get(ctx, bastKey(lockType, lockNumber))
	if err != nil || len(resp.Kvs) == 0 {
		return false, ""
	}
	val := string(resp.Kvs[0].Value)
	parts := strings.SplitN(val, ",", 2)
	if len(parts) == 2 && parts[1] != "" {
		return true, parts[1]
	}
	return false, ""
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

// GetEpoch returns the current cluster epoch revision.
// Returns 0 if the key doesn't exist yet (pre-bootstrap).
func (c *Client) GetEpoch(ctx context.Context) (int64, error) {
	resp, err := c.cli.Get(ctx, protocol.KeyEpoch)
	if err != nil {
		return 0, err
	}
	if resp.Count == 0 {
		return 0, nil
	}
	return resp.Kvs[0].ModRevision, nil
}

// InitEpoch writes the epoch key if it doesn't exist (first bootstrap).
func (c *Client) InitEpoch(ctx context.Context) (int64, error) {
	txnResp, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Version(protocol.KeyEpoch), "=", 0)).
		Then(clientv3.OpPut(protocol.KeyEpoch, "0")).
		Commit()
	if err != nil {
		return 0, err
	}
	return txnResp.Header.Revision, nil
}




func (c *Client) MarkFencingComplete(ctx context.Context, failedNodeID, result string) error {
	key := protocol.PrefixFencing + failedNodeID
	_, err := c.cli.Put(ctx, key, result)
	return err
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

func BuildTLSConfig(cfg *config.Config) (*tls.Config, error) {
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
