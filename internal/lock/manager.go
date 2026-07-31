package lock

import (
	"context"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/MHS-20/QAttach/internal/etcd"
	"github.com/MHS-20/QAttach/internal/netlink"
	"github.com/MHS-20/QAttach/pkg/protocol"
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
			// An unmapped mode would be stored as an empty holder
			// entry and then conflict with every other mode.
			log.Printf("lock request: unsupported mode %d type=%d num=%d",
				req.RequestedMode, req.GlockType, req.GlockNumber)
			m.sendDeny(req.RequestID, protocol.DenyReasonError)
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
		m.etcdCli.RequestBast(ctx, req.GlockType, req.GlockNumber,
			protocol.BastTargetMode(req.RequestedMode), m.nodeID)
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
	// Start the watcher before the initial check so a bast request
	// written in between is delivered rather than missed.  One watcher
	// for the lifetime of the held lock — the previous loop created a
	// fresh one per BAST cycle and never cancelled the old ones.
	bastCh := m.etcdCli.WatchBastRequests(ctx, lockType, lockNumber)

	if hasWaiter, target, _ := m.etcdCli.HasWaiter(ctx, lockType, lockNumber); hasWaiter {
		m.processBast(ctx, lockType, lockNumber, target)
	}

	for {
		select {
		case _, ok := <-bastCh:
			if !ok {
				return
			}
			hasWaiter, target, _ := m.etcdCli.HasWaiter(ctx, lockType, lockNumber)
			if hasWaiter {
				m.processBast(ctx, lockType, lockNumber, target)
			}
		case <-ctx.Done():
			return
		}
	}
}

func (m *Manager) processBast(ctx context.Context, lockType uint32, lockNumber uint64, targetMode uint32) {
	log.Printf("bast received: type=%d num=%d — demoting to %s",
		lockType, lockNumber, protocol.LockModeName(targetMode))

	if m.nlSrv != nil {
		m.nlSrv.SendBast(protocol.BastNotification{
			GlockType:   lockType,
			GlockNumber: lockNumber,
			TargetMode:  targetMode,
		})
	}

	m.etcdCli.DeleteBastRequest(ctx, lockType, lockNumber)
}

// retryProcessLock watches the lock key from the current etcd revision
// and retries ProcessLock on every change.  Starting the watch from the
// current revision ensures we don't miss events (key delete, /next write)
// that happen between the initial ProcessLock failure and the watch setup.
// For inode locks (type=2), uses a 5s timeout to prevent permanent D-state
// from GFS2's find_first_holder directory glock deadlock.
func (m *Manager) retryProcessLock(ctx context.Context, req protocol.LockRequest, mode string) {
	timeout := 120 * time.Second
	if req.GlockType == protocol.LockTypeInode {
		timeout = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// lm_lock returned 0, so the kernel left GLF_LOCK set and is waiting
	// for exactly one GRANT or DENY.  Any exit path that sends neither
	// wedges that glock — and everything queued behind it — forever.
	acquired := false
	defer func() {
		if acquired {
			return
		}
		log.Printf("retryProcessLock giving up type=%d num=%d — denying",
			req.GlockType, req.GlockNumber)
		bg := context.Background()
		m.etcdCli.RemoveWaiter(bg, req.GlockType, req.GlockNumber, m.nodeID)
		m.etcdCli.DeleteHandoff(bg, req.GlockType, req.GlockNumber)
		m.sendDeny(req.RequestID, protocol.DenyReasonContended)
	}()

	rev, _ := m.etcdCli.LockRev(ctx, req.GlockType, req.GlockNumber)
	watchCh := m.etcdCli.WatchLockFrom(ctx, req.GlockType, req.GlockNumber, rev+1)

	for {
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
			acquired = true
			m.etcdCli.RemoveWaiter(ctx, req.GlockType, req.GlockNumber, m.nodeID)
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
			m.trackHeldLock(req.GlockType, req.GlockNumber, mode)
			return
		}

		select {
		case <-ctx.Done():
			return
		case _, ok := <-watchCh:
			if !ok {
				return
			}
		}
	}
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
