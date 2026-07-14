package lock

import (
	"context"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/pkg/protocol"
)

type heldLock struct {
	cancel context.CancelFunc
	mode   string
}

type Manager struct {
	etcdCli *etcd.Client
	nlSrv   *netlink.Server
	nodeID  string

	mu        sync.Mutex
	mountReqs map[uint64]chan int32
	mountJID  int32
	heldLocks map[string]*heldLock
	epoch     int64
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

// ---- lock request handling ----

func (m *Manager) HandleLockRequest(req protocol.LockRequest) {
	go func() {
		ctx := context.Background()

		log.Printf("lock request: id=%d type=%d num=%d mode=%d epoch=%d",
			req.RequestID, req.GlockType, req.GlockNumber, req.RequestedMode, req.NodeEpoch)

		if req.NodeEpoch > 0 {
			m.mu.Lock()
			curEpoch := m.epoch
			m.mu.Unlock()
			if curEpoch > req.NodeEpoch {
				log.Printf("lock deny: stale epoch node=%d cluster=%d type=%d num=%d",
					req.NodeEpoch, curEpoch, req.GlockType, req.GlockNumber)
				m.sendDeny(req.RequestID, protocol.DenyReasonStaleEpoch)
				return
			}
		}

		mode := protocol.LockModeToEtcd(req.RequestedMode)
		if mode == "" {
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
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
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
		} else if holderNodeID == m.nodeID ||
			m.etcdCli.AmIHolder(ctx, req.GlockType, req.GlockNumber, m.nodeID) {
			log.Printf("lock self-contention: type=%d num=%d mode=%s→%s — converting",
				req.GlockType, req.GlockNumber, holderMode, mode)

			converted, rev, err := m.etcdCli.ConvertLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if err != nil {
				log.Printf("convert failed type=%d num=%d: %v — falling back to release+retry",
					req.GlockType, req.GlockNumber, err)
				m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
				m.etcdCli.AddWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
				m.sendWait(req.RequestID)
				go m.watchForLock(ctx, req)
				return
			}

			if converted {
				log.Printf("convert immediate: type=%d num=%d to %s",
					req.GlockType, req.GlockNumber, mode)
				m.sendGrant(req.RequestID, req.RequestedMode, rev)
				return
			}

			log.Printf("convert queued: type=%d num=%d to %s — waiting for other holders",
				req.GlockType, req.GlockNumber, mode)
			m.etcdCli.RequestBast(ctx, req.GlockType, req.GlockNumber, 0, m.nodeID)
			m.sendWait(req.RequestID)
			go m.watchForConversion(ctx, req, mode)
		} else {
			log.Printf("lock contended by %s, waiting", holderNodeID)
			m.etcdCli.AddWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
			m.etcdCli.RequestBast(ctx,
				req.GlockType, req.GlockNumber, 0, m.nodeID)
			m.sendWait(req.RequestID)
			go m.watchForLock(ctx, req)
		}
	}()
}

func (m *Manager) trackHeldLock(lockType uint32, lockNumber uint64, mode string) {
	ctx, cancel := context.WithCancel(context.Background())
	mapKey := lockMapKey(lockType, lockNumber)
	m.mu.Lock()
	if prev, ok := m.heldLocks[mapKey]; ok {
		prev.cancel()
	}
	m.heldLocks[mapKey] = &heldLock{cancel: cancel, mode: mode}
	m.mu.Unlock()

	go m.watchBastAndYield(ctx, lockType, lockNumber)
}

// watchBastAndYield watches the BAST key for a lock we hold.
// When a BAST appears: send BAST to kernel, release the etcd key,
// and let waiters acquire via FIFO.  Does NOT reacquire.
func (m *Manager) watchBastAndYield(ctx context.Context, lockType uint32, lockNumber uint64) {
	for {
		bastCh := m.etcdCli.WatchLockBast(ctx, lockType, lockNumber)

		hasWaiter, _ := m.etcdCli.HasWaiter(context.Background(), lockType, lockNumber)
		if hasWaiter {
			select {
			case <-ctx.Done():
				return
			default:
			}
			m.processBast(lockType, lockNumber)
			return
		}

		select {
		case _, ok := <-bastCh:
			if !ok {
				return
			}
			m.processBast(lockType, lockNumber)
			return
		case <-ctx.Done():
			return
		}
	}
}

func (m *Manager) processBast(lockType uint32, lockNumber uint64) {
	log.Printf("bast received: type=%d num=%d — yielding", lockType, lockNumber)

	if m.nlSrv != nil {
		m.nlSrv.SendBast(protocol.BastNotification{
			GlockType:   lockType,
			GlockNumber: lockNumber,
			TargetMode:  0,
		})
	}

	m.etcdCli.DeleteBastRequest(context.Background(), lockType, lockNumber)
}

// watchForLock polls the lock key until this node can acquire as first waiter.
func (m *Manager) watchForLock(ctx context.Context, req protocol.LockRequest) {
	mode := protocol.LockModeToEtcd(req.RequestedMode)
	if mode == "" {
		return
	}

	// Pre-check: the lock may already be free.
	if m.tryAcquireAsFirstWaiter(ctx, req) {
		return
	}

	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if m.tryAcquireAsFirstWaiter(ctx, req) {
				return
			}
		}
	}
}

// watchForConversion polls the lock key until the conversion can proceed.
func (m *Manager) watchForConversion(ctx context.Context, req protocol.LockRequest, mode string) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	diagNext := time.Now()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			converted, rev, err := m.etcdCli.ConvertLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if err != nil {
				log.Printf("watchForConversion: convert error type=%d num=%d: %v",
					req.GlockType, req.GlockNumber, err)
				return
			}
			if converted {
				log.Printf("watchForConversion: converted type=%d num=%d to %s",
					req.GlockType, req.GlockNumber, mode)
				m.sendGrant(req.RequestID, req.RequestedMode, rev)
				return
			}
			if time.Now().After(diagNext) {
				raw, exists, _ := m.etcdCli.GetLockRaw(ctx,
					req.GlockType, req.GlockNumber)
				log.Printf("watchForConversion: still waiting type=%d num=%d node=%s mode=%s exists=%v raw=%s",
					req.GlockType, req.GlockNumber, m.nodeID, mode, exists, raw)
				diagNext = time.Now().Add(10 * time.Second)

				// BAST other PR holders so they release.
				m.etcdCli.RequestBast(ctx,
					req.GlockType, req.GlockNumber, 0, m.nodeID)

				// Fallback: if the lock key vanished (deleted by
				// session expiry or the other node), just acquire.
				if !exists {
					granted, rev, _, _, aerr := m.etcdCli.AcquireLock(ctx,
						req.GlockType, req.GlockNumber, m.nodeID, mode)
					if aerr == nil && granted {
						log.Printf("watchForConversion: fallback acquired type=%d num=%d",
							req.GlockType, req.GlockNumber)
						m.sendGrant(req.RequestID, req.RequestedMode, rev)
						return
					}
				}
			}
		}
	}
}

func (m *Manager) tryAcquireAsFirstWaiter(ctx context.Context, req protocol.LockRequest) bool {
	isFirst, err := m.etcdCli.IsFirstWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
	if err != nil {
		log.Printf("IsFirstWaiter error type=%d num=%d: %v",
			req.GlockType, req.GlockNumber, err)
		return false
	}

	mode := protocol.LockModeToEtcd(req.RequestedMode)
	if isFirst {
		granted, rev, _, _, err := m.etcdCli.AcquireLock(ctx,
			req.GlockType, req.GlockNumber, m.nodeID, mode)
		if err != nil {
			log.Printf("first-waiter acquire error type=%d num=%d: %v",
				req.GlockType, req.GlockNumber, err)
			return false
		}
		if granted {
			log.Printf("first-waiter acquired: type=%d num=%d rev=%d",
				req.GlockType, req.GlockNumber, rev)
			m.etcdCli.RemoveWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
			return true
		}
		log.Printf("first-waiter but acquire failed type=%d num=%d",
			req.GlockType, req.GlockNumber)
		return false
	}

	// No waiters exist (our wait key may have been lost). If the lock
	// key is free, acquire it anyway — we may have missed the handoff.
	granted, rev, _, _, err := m.etcdCli.AcquireLock(ctx,
		req.GlockType, req.GlockNumber, m.nodeID, mode)
	if err != nil {
		return false
	}
	if granted {
		log.Printf("orphan-waiter acquired: type=%d num=%d rev=%d",
			req.GlockType, req.GlockNumber, rev)
		m.sendGrant(req.RequestID, req.RequestedMode, rev)
		m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
		return true
	}
	return false
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
	if err := m.etcdCli.ReleaseLock(ctx, lockType, lockNumber, m.nodeID); err != nil {
		log.Printf("release lock error type=%d num=%d: %v",
			lockType, lockNumber, err)
	}
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
			m.sendMountResponse(req.RequestID, -1, 0)
			return
		}

		epoch, err := m.etcdCli.GetEpoch(ctx)
		if err != nil {
			log.Printf("epoch read error: %v", err)
			epoch = 0
		}

		m.mu.Lock()
		m.mountJID = jid
		m.epoch = epoch
		m.mu.Unlock()

		log.Printf("mount request: cluster=%s, assigned jid=%d, epoch=%d",
			cstring(req.FilesystemName[:]), jid, epoch)
		m.sendMountResponse(req.RequestID, jid, epoch)
	}()
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

func (m *Manager) sendMountResponse(requestID uint64, jid int32, epoch int64) {
	if m.nlSrv == nil {
		log.Printf("mount response NOT SENT: netlink server is nil")
		return
	}
	log.Printf("sending mount response: jid=%d epoch=%d via netlink", jid, epoch)
	if err := m.nlSrv.SendMountResponse(protocol.MountResponse{
		RequestID: requestID, JID: jid, Epoch: epoch,
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
