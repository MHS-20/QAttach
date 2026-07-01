package lock

import (
	"context"
	"log"
	"strconv"
	"sync"

	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/pkg/protocol"
)

// lockOrderKey produces the global sort key used to serialise lock
// acquisition across all nodes.  Matches the kernel's letcd_order_key.
// Lower keys must be acquired before higher keys on every node.
func lockOrderKey(lockType uint32, lockNumber uint64) uint64 {
	return (uint64(lockType) << 56) | (lockNumber & 0x00FFFFFFFFFFFFFF)
}

type heldLock struct {
	cancel   context.CancelFunc
	mode     string
	orderKey uint64
}

type Manager struct {
	etcdCli *etcd.Client
	nlSrv   *netlink.Server
	nodeID  string

	mu        sync.Mutex
	mountReqs map[uint64]chan int32
	mountJID  int32
	heldLocks map[string]*heldLock
}

func NewManager(ec *etcd.Client, nodeID string) *Manager {
	return &Manager{
		etcdCli:   ec,
		nodeID:    nodeID,
		mountReqs: make(map[uint64]chan int32),
		mountJID:  -1,
		heldLocks: make(map[string]*heldLock),
	}
}

func (m *Manager) SetNetlink(srv *netlink.Server) { m.nlSrv = srv }

func lockMapKey(lockType uint32, lockNumber uint64) string {
	return strconv.FormatUint(uint64(lockType), 10) + "/" +
		strconv.FormatUint(lockNumber, 10)
}

// ---- lock ordering ----

// holdsHigherLock returns true if this node already holds a lock whose
// sort key is strictly greater than the requested key.  That means the
// node is trying to acquire locks out of the global order and must
// release the higher-key lock first.
func (m *Manager) holdsHigherLock(reqOrderKey uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, hl := range m.heldLocks {
		if hl.orderKey > reqOrderKey {
			return true
		}
	}
	return false
}

// ---- lock request handling ----

func (m *Manager) HandleLockRequest(req protocol.LockRequest) {
	go func() {
		ctx := context.Background()

		log.Printf("lock request: id=%d type=%d num=%d mode=%d",
			req.RequestID, req.GlockType, req.GlockNumber, req.RequestedMode)

		mode := protocol.LockModeToEtcd(req.RequestedMode)
		if mode == "" {
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
			return
		}

		orderKey := lockOrderKey(req.GlockType, req.GlockNumber)

		// Global ordering: a node must acquire locks in ascending
		// sorted order.  If it already holds a higher-key lock,
		// deny this request so GFS2 releases the higher locks first.
		//
		// This prevents the AB/BA deadlock: if Node 0 holds A
		// (lower key) and Node 1 holds B (higher key), Node 1
		// cannot get A because B has a higher key — Node 1 must
		// release B first.  Node 0 can then get both.
		if m.holdsHigherLock(orderKey) {
			log.Printf("lock out-of-order: type=%d num=%d (order=%x) — waiting for higher locks to release",
				req.GlockType, req.GlockNumber, orderKey)
			m.sendWait(req.RequestID)
			go m.watchAndRetry(ctx, req)
			return
		}

		granted, rev, holderMode, holderNodeID, err :=
			m.etcdCli.AcquireLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
		if err != nil {
			log.Printf("lock acquire error type=%d num=%d: %v",
				req.GlockType, req.GlockNumber, err)
			m.sendDeny(req.RequestID, protocol.DenyReasonError)
			return
		}

		if granted {
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode, orderKey)
		} else if holderNodeID == m.nodeID {
			log.Printf("lock self-contention: type=%d num=%d holder=%s→%s",
				req.GlockType, req.GlockNumber, holderMode, mode)
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
			g2, r2, _, _, e2 := m.etcdCli.AcquireLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if e2 != nil {
				log.Printf("self-contention reacquire error: %v", e2)
				m.sendDeny(req.RequestID, protocol.DenyReasonError)
				return
			}
			if g2 {
				m.sendGrant(req.RequestID, req.RequestedMode, r2)
				m.trackHeldLock(req.GlockType, req.GlockNumber, mode, orderKey)
			} else {
				m.sendWait(req.RequestID)
				go m.watchAndRetry(ctx, req)
			}
		} else {
			log.Printf("lock contended by %s (mode=%s), waiting",
				holderNodeID, holderMode)
			m.sendWait(req.RequestID)
			go m.watchAndRetry(ctx, req)
		}
	}()
}

func (m *Manager) trackHeldLock(lockType uint32, lockNumber uint64, mode string, orderKey uint64) {
	ctx, cancel := context.WithCancel(context.Background())
	mapKey := lockMapKey(lockType, lockNumber)
	m.mu.Lock()
	if prev, ok := m.heldLocks[mapKey]; ok {
		prev.cancel()
	}
	m.heldLocks[mapKey] = &heldLock{cancel: cancel, mode: mode, orderKey: orderKey}
	m.mu.Unlock()
	_ = ctx
}

func (m *Manager) releaseHeldLock(ctx context.Context, lockType uint32, lockNumber uint64) {
	mapKey := lockMapKey(lockType, lockNumber)
	m.mu.Lock()
	hl, ok := m.heldLocks[mapKey]
	if ok {
		delete(m.heldLocks, mapKey)
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	hl.cancel()
	m.etcdCli.ReleaseLock(ctx, lockType, lockNumber, m.nodeID)
	log.Printf("released lock type=%d num=%d mode=%s",
		lockType, lockNumber, hl.mode)
}

func (m *Manager) HandleLockRelease(req protocol.LockRelease) {
	ctx := context.Background()
	m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
}

func (m *Manager) HandleUnmount() {
	log.Printf("filesystem unmounting — releasing all resources")
}

func (m *Manager) HandleMountRequest(req protocol.MountRequest) {
	go func() {
		ctx := context.Background()
		jid, err := m.etcdCli.AssignJournal(ctx, m.nodeID, protocol.MaxJournals)
		if err != nil {
			log.Printf("journal assignment error: %v", err)
			jid = -1
		}
		if jid < 0 {
			log.Printf("mount request: no free journal slots")
			m.sendMountResponse(req.RequestID, -1)
			return
		}
		m.mountJID = jid
		log.Printf("mount request: cluster=%s, assigned jid=%d",
			cstring(req.FilesystemName[:]), jid)
		m.sendMountResponse(req.RequestID, jid)
	}()
}

func (m *Manager) watchAndRetry(ctx context.Context, req protocol.LockRequest) {
	watchCh := m.etcdCli.WatchLockKey(ctx, req.GlockType, req.GlockNumber)
	for resp := range watchCh {
		for _, ev := range resp.Events {
			if ev.Type == 1 { // DELETE
				mode := protocol.LockModeToEtcd(req.RequestedMode)
				orderKey := lockOrderKey(req.GlockType, req.GlockNumber)

				if m.holdsHigherLock(orderKey) {
					log.Printf("retry out-of-order: type=%d num=%d — waiting for higher locks to release",
						req.GlockType, req.GlockNumber)
					// Higher locks still held; keep watching.
					continue
				}

				granted, rev, _, _, err := m.etcdCli.AcquireLock(ctx,
					req.GlockType, req.GlockNumber, m.nodeID, mode)
				if err != nil {
					log.Printf("retry lock acquire error: %v", err)
					m.sendDeny(req.RequestID, protocol.DenyReasonError)
					return
				}
				if granted {
					m.sendGrant(req.RequestID, req.RequestedMode, rev)
					m.trackHeldLock(req.GlockType, req.GlockNumber, mode, orderKey)
				}
				return
			}
		}
	}
}

// ---- netlink helpers ----

func (m *Manager) sendGrant(requestID uint64, mode uint32, revision int64) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendLockGrant(protocol.LockGrant{
		RequestID: requestID, GrantedMode: mode, EtcdRevision: revision,
	}); err != nil {
		log.Printf("send grant error: %v", err)
	}
}

func (m *Manager) sendDeny(requestID uint64, reason uint32) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendLockDeny(protocol.LockDeny{
		RequestID: requestID, Reason: reason,
	}); err != nil {
		log.Printf("send deny error: %v", err)
	}
}

func (m *Manager) sendWait(requestID uint64) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendLockWait(protocol.LockWait{
		RequestID: requestID,
	}); err != nil {
		log.Printf("send wait error: %v", err)
	}
}

func (m *Manager) sendMountResponse(requestID uint64, jid int32) {
	if m.nlSrv == nil {
		log.Printf("mount response NOT SENT: netlink server is nil")
		return
	}
	log.Printf("sending mount response: jid=%d via netlink", jid)
	if err := m.nlSrv.SendMountResponse(protocol.MountResponse{
		RequestID: requestID, JID: jid,
	}); err != nil {
		log.Printf("send mount response error: %v", err)
	}
}

func cstring(b []byte) string {
	for i, v := range b {
		if v == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}
