package etcd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/client/v3/concurrency"

	"github.com/MHS-20/QAttach/internal/config"
	"github.com/MHS-20/QAttach/pkg/protocol"
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

// Done closes when the session lease expires.  Every member, journal and
// lock key this node owns is attached to that lease, so etcd drops them
// all at once while GFS2 still believes it holds the corresponding
// glocks.  Callers must treat this as loss of cluster membership.
func (c *Client) Done() <-chan struct{} {
	return c.sess.Done()
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

// ---- lock operations ----

// modesConflict returns true if two lock modes held on the same object
// conflict, per the DLM compatibility matrix GFS2 assumes (see may_grant
// in fs/gfs2/glock.c): EX excludes everything, PR and CW are each
// compatible only with themselves, and PR/CW exclude each other.
func modesConflict(a, b string) bool {
	return a != b || a == protocol.EtcdModeEX
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

		// Key doesn't exist — check handoff FIFO ordering.
		if len(getResp.Kvs) == 0 {
			// If a handoff marker exists for a different node,
			// refuse so the designated next holder can claim
			// the lock first (FIFO — like DLM's grant queue).
			hk := handoffKey(lockType, lockNumber)
			hResp, hErr := c.cli.Get(ctx, hk)
			var hVer int64
			designated := ""
			if hErr == nil && len(hResp.Kvs) > 0 {
				designated = string(hResp.Kvs[0].Value)
				hVer = hResp.Kvs[0].Version
			}
			if designated != "" && designated != nodeID {
				return false, 0, nil
			}

			val := marshalHolders([]lockEntry{{Node: nodeID, Mode: mode}})

			conds := []clientv3.Cmp{
				clientv3.Compare(clientv3.Version(key), "=", 0),
			}
			ops := []clientv3.Op{
				clientv3.OpPut(key, val, clientv3.WithLease(c.sess.Lease())),
			}

			if designated == nodeID {
				// We are the designated next holder —
				// atomically delete the marker.
				conds = append(conds,
					clientv3.Compare(clientv3.Version(hk), "=", hVer))
				ops = append(ops, clientv3.OpDelete(hk))
			}

			txnResp, err := c.cli.Txn(ctx).
				If(conds...).
				Then(ops...).
				Else(clientv3.OpGet(key)).
				Commit()
			if err != nil {
				return false, 0, fmt.Errorf("process empty txn: %w", err)
			}
			if !txnResp.Succeeded {
				continue // key/marker changed — retry
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

		// A conflicting holder blocks this mode, whether we are
		// converting or acquiring fresh.  Leave any entry we already
		// have untouched and return false: BAST drives the holder
		// out and the retry goroutine converts afterwards.
		for i, h := range holders {
			if i == ourIdx {
				continue
			}
			if modesConflict(mode, h.Mode) {
				return false, 0, nil
			}
		}

		if ourIdx >= 0 && holders[ourIdx].Mode == mode {
			return true, getResp.Kvs[0].ModRevision, nil
		}

		newHolders := make([]lockEntry, len(holders), len(holders)+1)
		copy(newHolders, holders)
		if ourIdx >= 0 {
			newHolders[ourIdx].Mode = mode
		} else {
			newHolders = append(newHolders, lockEntry{Node: nodeID, Mode: mode})
		}

		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", ver)).
			Then(clientv3.OpPut(key, marshalHolders(newHolders),
				clientv3.WithLease(c.sess.Lease()))).
			Commit()
		if err != nil {
			return false, 0, fmt.Errorf("process txn: %w", err)
		}
		if !txnResp.Succeeded {
			continue
		}
		return true, txnResp.Header.Revision, nil
	}
}

// ReleaseLock removes this node's entry from the holders array, retrying
// on CAS version mismatch (concurrent multi-holder release).
//
// When that leaves the key empty it is deleted, and if waiters are queued
// the delete and a FIFO reservation for the first of them commit in the
// same transaction — no other node, including this one, can reclaim the
// lock in between.  Returns the reserved node, or "" if none.
func (c *Client) ReleaseLock(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) (string, error) {
	key := lockKey(lockType, lockNumber)

	for {
		getResp, err := c.cli.Get(ctx, key)
		if err != nil {
			return "", err
		}
		if len(getResp.Kvs) == 0 {
			return "", nil
		}

		ver := getResp.Kvs[0].Version
		filtered := make([]lockEntry, 0, 1)
		for _, h := range parseHolders(getResp.Kvs[0].Value) {
			if h.Node != nodeID {
				filtered = append(filtered, h)
			}
		}

		target := ""
		var ops []clientv3.Op
		if len(filtered) > 0 {
			ops = []clientv3.Op{clientv3.OpPut(key, marshalHolders(filtered),
				clientv3.WithLease(c.sess.Lease()))}
		} else {
			ops = []clientv3.Op{clientv3.OpDelete(key)}
			if target, err = c.reserveHandoff(ctx, lockType, lockNumber, &ops); err != nil {
				return "", err
			}
		}

		txnResp, err := c.cli.Txn(ctx).
			If(clientv3.Compare(clientv3.Version(key), "=", ver)).
			Then(ops...).
			Commit()
		if err != nil {
			return "", err
		}
		if txnResp.Succeeded {
			return target, nil
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

// reserveHandoff appends a FIFO reservation for the longest-waiting node
// to ops, so it commits together with the caller's lock-key delete.
// Returns the reserved node, or "" when nobody is waiting.
func (c *Client) reserveHandoff(ctx context.Context, lockType uint32, lockNumber uint64, ops *[]clientv3.Op) (string, error) {
	waiters, err := c.GetWaiters(ctx, lockType, lockNumber)
	if err != nil || len(waiters) == 0 {
		return "", err
	}

	// The reservation gets its own short lease rather than this node's
	// session lease: if the designated waiter dies before claiming, the
	// marker must expire on its own, or it blocks the lock for as long
	// as the releasing node stays alive.
	lease, err := c.cli.Grant(ctx, protocol.HandoffLeaseTTL)
	if err != nil {
		return "", fmt.Errorf("handoff lease grant: %w", err)
	}

	*ops = append(*ops, clientv3.OpPut(handoffKey(lockType, lockNumber),
		waiters[0], clientv3.WithLease(lease.ID)))
	return waiters[0], nil
}

// DeleteHandoff clears the handoff reservation, but only when it names
// nodeID.  Deleting another node's reservation would break the FIFO
// ordering that stops a releasing holder from immediately reacquiring.
func (c *Client) DeleteHandoff(ctx context.Context, lockType uint32, lockNumber uint64, nodeID string) error {
	hk := handoffKey(lockType, lockNumber)
	_, err := c.cli.Txn(ctx).
		If(clientv3.Compare(clientv3.Value(hk), "=", nodeID)).
		Then(clientv3.OpDelete(hk)).
		Commit()
	return err
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

// HasWaiter reports whether a bast request exists, returning the mode the
// holder must demote to and the waiter's nodeID.
func (c *Client) HasWaiter(ctx context.Context, lockType uint32, lockNumber uint64) (bool, uint32, string) {
	resp, err := c.cli.Get(ctx, bastKey(lockType, lockNumber))
	if err != nil || len(resp.Kvs) == 0 {
		return false, 0, ""
	}
	parts := strings.SplitN(string(resp.Kvs[0].Value), ",", 2)
	if len(parts) != 2 || parts[1] == "" {
		return false, 0, ""
	}
	mode, err := strconv.ParseUint(parts[0], 10, 32)
	if err != nil {
		return false, 0, ""
	}
	return true, uint32(mode), parts[1]
}

func (c *Client) DeleteBastRequest(ctx context.Context, lockType uint32, lockNumber uint64) error {
	_, err := c.cli.Delete(ctx, bastKey(lockType, lockNumber))
	return err
}

// WatchBastRequests signals once per newly written bast request.  Deletes
// are filtered out: the holder deletes the key itself in response, and
// echoing that back would send the kernel a second, spurious BAST.
func (c *Client) WatchBastRequests(ctx context.Context, lockType uint32, lockNumber uint64) <-chan struct{} {
	wch := c.cli.Watch(ctx, bastKey(lockType, lockNumber))
	out := make(chan struct{}, 1)

	go func() {
		defer close(out)
		for resp := range wch {
			for _, ev := range resp.Events {
				if ev.Type != clientv3.EventTypePut {
					continue
				}
				select {
				case out <- struct{}{}:
				case <-ctx.Done():
					return
				}
				break
			}
		}
	}()
	return out
}

// WatchLockFrom returns a watch channel starting from rev, so events
// between the initial Get and the watch start are not missed.
func (c *Client) WatchLockFrom(ctx context.Context, lockType uint32, lockNumber uint64, rev int64) clientv3.WatchChan {
	return c.cli.Watch(ctx, lockKey(lockType, lockNumber), clientv3.WithRev(rev))
}

// LockRev returns the current etcd revision for the lock key.
func (c *Client) LockRev(ctx context.Context, lockType uint32, lockNumber uint64) (int64, error) {
	resp, err := c.cli.Get(ctx, lockKey(lockType, lockNumber))
	if err != nil {
		return 0, err
	}
	if resp.Header == nil {
		return 0, nil
	}
	return resp.Header.Revision, nil
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
