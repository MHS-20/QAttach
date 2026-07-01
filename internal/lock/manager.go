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
			// Re-check after release: another node may have
			// written a bast key while we were releasing.
			hasWaiter, waiterID := m.etcdCli.HasWaiter(ctx,
				req.GlockType, req.GlockNumber)
			if hasWaiter && waiterID != "" && waiterID != m.nodeID {
				log.Printf("self-contention yielding: type=%d num=%d waiter=%s",
					req.GlockType, req.GlockNumber, waiterID)
				// Tell kernel to suppress reacquire.
				m.sendLockYield(req.GlockType, req.GlockNumber)
				m.etcdCli.DeleteBastRequest(ctx,
					req.GlockType, req.GlockNumber)
				m.sendWait(req.RequestID)
				go m.watchAndRetryYield(ctx, req)
				return
			}
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
			// Contended by another node.  Write a handoff token
			// so the holder yields on its next self-contention.
			m.etcdCli.RequestBast(ctx,
				req.GlockType, req.GlockNumber, 0, m.nodeID)
			log.Printf("lock contended by %s, waiting",
				holderNodeID)
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
			// DELETE (Type=1) or PUT (Type=0): any change may
			// mean the lock became available (self-contention
			// yield removed a holder, etc).
			if ev.Type == 1 || ev.Type == 0 {
				mode := protocol.LockModeToEtcd(req.RequestedMode)
				orderKey := lockOrderKey(req.GlockType, req.GlockNumber)

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

func (m *Manager) sendLockYield(lockType uint32, lockNumber uint64) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendLockYield(protocol.LockYield{
		GlockType: lockType, GlockNumber: lockNumber,
	}); err != nil {
		log.Printf("send lock yield error: %v", err)
	} else {
		log.Printf("sent lock yield: type=%d num=%d",
			lockType, lockNumber)
	}
}

func (m *Manager) sendYieldClear(lockType uint32, lockNumber uint64) {
	if m.nlSrv == nil {
		return
	}
	m.nlSrv.SendYieldClear(protocol.LockYield{
		GlockType: lockType, GlockNumber: lockNumber,
	})
}

// watchAndRetryYield is like watchAndRetry but clears the yield
// flag when the lock is finally acquired.
func (m *Manager) watchAndRetryYield(ctx context.Context,
	req protocol.LockRequest) {
	watchCh := m.etcdCli.WatchLockKey(ctx,
		req.GlockType, req.GlockNumber)
	for resp := range watchCh {
		for _, ev := range resp.Events {
			if ev.Type == 1 || ev.Type == 0 {
				mode := protocol.LockModeToEtcd(req.RequestedMode)
				orderKey := lockOrderKey(req.GlockType, req.GlockNumber)

				granted, rev, _, _, err := m.etcdCli.AcquireLock(ctx,
					req.GlockType, req.GlockNumber, m.nodeID, mode)
				if err != nil {
					log.Printf("retry lock acquire error: %v", err)
					m.sendDeny(req.RequestID, protocol.DenyReasonError)
					return
				}
				if granted {
					m.sendYieldClear(req.GlockType, req.GlockNumber)
					m.sendGrant(req.RequestID, req.RequestedMode, rev)
					m.trackHeldLock(req.GlockType, req.GlockNumber,
						mode, orderKey)
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
