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
	heldLocks map[string]*heldLock
	epoch     int64
}

func NewManager(ec *etcd.Client, nodeID string) *Manager {
	return &Manager{
		etcdCli:   ec,
		nodeID:    nodeID,
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

		log.Printf("lock request: id=%d type=%d num=%d mode=%d",
			req.RequestID, req.GlockType, req.GlockNumber, req.RequestedMode)

		mode := protocol.LockModeToEtcd(req.RequestedMode)
		if mode == "" {
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
			return
		}

		granted, rev, err := m.etcdCli.ProcessLock(ctx,
			req.GlockType, req.GlockNumber, m.nodeID, mode)
		if err != nil {
			log.Printf("process lock error type=%d num=%d: %v",
				req.GlockType, req.GlockNumber, err)
			m.sendDeny(req.RequestID, protocol.DenyReasonError)
			return
		}

		if granted {
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
			return
		}

		// Journal lock (type=9) held by another live node:
		// the holder won't release (GFS2 holds journal EX while mounted).
		// Deny immediately so the kernel's mount skips this journal.
		if req.GlockType == protocol.LockTypeJournal &&
			req.RequestedMode == protocol.LockModeExclusive {
			log.Printf("journal lock denied: type=%d num=%d — held by live node, skipping",
				req.GlockType, req.GlockNumber)
			m.sendDeny(req.RequestID, protocol.DenyReasonContended)
			return
		}

		// WAIT — conflicts exist.  Start the retry goroutine.
		m.etcdCli.AddWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
		m.etcdCli.RequestBast(ctx,
			req.GlockType, req.GlockNumber, 0, m.nodeID)
		m.sendWait(req.RequestID)
		go m.retryProcessLock(ctx, req, mode)
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

// watchForConversion polls the lock key until the conversion can proceed.
func (m *Manager) watchForConversion(ctx context.Context, req protocol.LockRequest, mode string) {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			converted, rev, err := m.etcdCli.ConvertLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if err != nil {
				log.Printf("watchForConversion: convert error type=%d num=%d: %v — trying fallback",
					req.GlockType, req.GlockNumber, err)
				granted, rev, _, _, aerr := m.etcdCli.AcquireLock(ctx,
					req.GlockType, req.GlockNumber, m.nodeID, mode)
				if aerr == nil && granted {
					log.Printf("watchForConversion: fallback acquired type=%d num=%d",
						req.GlockType, req.GlockNumber)
					m.sendGrant(req.RequestID, req.RequestedMode, rev)
				}
				return
			}
			if converted {
				log.Printf("watchForConversion: converted type=%d num=%d to %s",
					req.GlockType, req.GlockNumber, mode)
				m.sendGrant(req.RequestID, req.RequestedMode, rev)
				return
			}

			// BAST other PR holders so they release.
			m.etcdCli.RequestBast(ctx,
				req.GlockType, req.GlockNumber, 0, m.nodeID)
		}
	}
}

// retryProcessLock periodically retries ProcessLock until the lock is granted
// or the retry times out (120s). On timeout, the waiter entry is cleaned up
// and a DENY is sent to the kernel so GFS2 can move on.
func (m *Manager) retryProcessLock(ctx context.Context, req protocol.LockRequest, mode string) {
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()

	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("retryProcessLock timeout type=%d num=%d — denying",
				req.GlockType, req.GlockNumber)
			m.etcdCli.RemoveWaiter(context.Background(),
				req.GlockType, req.GlockNumber, m.nodeID)
			m.etcdCli.DeleteHandoff(context.Background(),
				req.GlockType, req.GlockNumber)
			m.sendDeny(req.RequestID, protocol.DenyReasonContended)
			return
		case <-ticker.C:
			granted, rev, err := m.etcdCli.ProcessLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if err != nil {
				log.Printf("retryProcessLock error type=%d num=%d: %v",
					req.GlockType, req.GlockNumber, err)
				return
			}
			if granted {
				log.Printf("retryProcessLock acquired: type=%d num=%d rev=%d",
					req.GlockType, req.GlockNumber, rev)
				m.etcdCli.RemoveWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
				m.sendGrant(req.RequestID, req.RequestedMode, rev)
				m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
				return
			}
		}
	}
}

func (m *Manager) tryAcquireAsFirstWaiter(ctx context.Context, req protocol.LockRequest) bool {
	mode := protocol.LockModeToEtcd(req.RequestedMode)

	// Check handoff marker: if the previous holder designated us,
	// delete the marker and acquire immediately.
	isHandoff, err := m.etcdCli.CheckHandoff(ctx,
		req.GlockType, req.GlockNumber, m.nodeID)
	if err == nil && isHandoff {
		granted, rev, _, _, aerr := m.etcdCli.AcquireLock(ctx,
			req.GlockType, req.GlockNumber, m.nodeID, mode)
		if aerr == nil && granted {
			log.Printf("handoff acquired: type=%d num=%d rev=%d",
				req.GlockType, req.GlockNumber, rev)
			m.etcdCli.RemoveWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
			return true
		}
	}

	granted, rev, _, _, err := m.etcdCli.AcquireLock(ctx,
		req.GlockType, req.GlockNumber, m.nodeID, mode)
	if err != nil {
		return false
	}
	if granted {
		log.Printf("acquired: type=%d num=%d rev=%d",
			req.GlockType, req.GlockNumber, rev)
		m.etcdCli.RemoveWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
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

	if ok {
		hl.cancel()
		if err := m.etcdCli.ReleaseLock(ctx, lockType, lockNumber, m.nodeID); err != nil {
			log.Printf("release lock error type=%d num=%d: %v",
				lockType, lockNumber, err)
		}
		log.Printf("released lock type=%d num=%d mode=%s",
			lockType, lockNumber, hl.mode)
		return
	}

	// Untracked — still clean up etcd.
	if err := m.etcdCli.ReleaseLock(ctx, lockType, lockNumber, m.nodeID); err != nil {
		log.Printf("release untracked lock error type=%d num=%d: %v",
			lockType, lockNumber, err)
	}
}

func (m *Manager) HandleLockRelease(req protocol.LockRelease) {
	ctx := context.Background()

	mapKey := lockMapKey(req.GlockType, req.GlockNumber)
	m.mu.Lock()
	hl, ok := m.heldLocks[mapKey]
	if ok {
		delete(m.heldLocks, mapKey)
	}
	m.mu.Unlock()

	if ok {
		hl.cancel()
		target, err := m.etcdCli.HandoffRelease(ctx,
			req.GlockType, req.GlockNumber, m.nodeID)
		if err != nil {
			log.Printf("handoff error type=%d num=%d: %v",
				req.GlockType, req.GlockNumber, err)
			return
		}
		if target != "" {
			log.Printf("handoff: type=%d num=%d → %s",
				req.GlockType, req.GlockNumber, target)
		}
		log.Printf("released lock type=%d num=%d mode=%s",
			req.GlockType, req.GlockNumber, hl.mode)
		return
	}

	// Lock not tracked locally (agent restarted, or untracked
	// lock type).  Still release from etcd so the key is cleaned up.
	if err := m.etcdCli.ReleaseLock(ctx, req.GlockType, req.GlockNumber, m.nodeID); err != nil {
		log.Printf("release untracked lock error type=%d num=%d: %v",
			req.GlockType, req.GlockNumber, err)
	}
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
