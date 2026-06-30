package lock

import (
	"context"
	"log"
	"strconv"
	"strings"
	"sync"

	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/pkg/protocol"
)

// heldLock tracks a lock held by this node.
type heldLock struct {
	cancel       context.CancelFunc
	mode         string // etcd mode: EX, PR, CW
	waiterNodeID string // non-empty if a BAST-triggered handoff is pending
}

// Manager handles glock requests from the kernel module via etcd.
type Manager struct {
	etcdCli *etcd.Client
	nlSrv   *netlink.Server
	nodeID  string

	mu        sync.Mutex
	mountReqs map[uint64]chan int32
	mountJID  int32
	nextJID   int32
	heldLocks map[string]*heldLock
}

func NewManager(ec *etcd.Client, nodeID string) *Manager {
	return &Manager{
		etcdCli:   ec,
		nodeID:    nodeID,
		mountReqs: make(map[uint64]chan int32),
		mountJID:  -1,
		nextJID:   0,
		heldLocks: make(map[string]*heldLock),
	}
}

func (m *Manager) SetNetlink(srv *netlink.Server) {
	m.nlSrv = srv
}

func lockMapKey(lockType uint32, lockNumber uint64) string {
	return strconv.FormatUint(uint64(lockType), 10) + "/" +
		strconv.FormatUint(lockNumber, 10)
}

// ---- lock compatibility ----

func etcdModeToNum(etcdMode string) uint32 {
	switch etcdMode {
	case protocol.EtcdModeEX:
		return protocol.LockModeExclusive
	case protocol.EtcdModeCW:
		return protocol.LockModeDeferred
	case protocol.EtcdModePR:
		return protocol.LockModeShared
	default:
		return protocol.LockModeUnlocked
	}
}

func compatibleBastMode(holderEtcdMode string, requesterMode uint32) (uint32, bool) {
	h := etcdModeToNum(holderEtcdMode)
	r := requesterMode

	if h == protocol.LockModeShared && r == protocol.LockModeShared {
		return 0, false
	}

	switch h {
	case protocol.LockModeExclusive:
		if r == protocol.LockModeShared {
			return protocol.LockModeShared, true
		}
		return 0, false

	case protocol.LockModeDeferred:
		if r == protocol.LockModeShared {
			return protocol.LockModeShared, true
		}
		if r == protocol.LockModeExclusive {
			return protocol.LockModeUnlocked, true
		}
		return 0, false

	case protocol.LockModeShared:
		if r == protocol.LockModeExclusive || r == protocol.LockModeDeferred {
			return protocol.LockModeUnlocked, true
		}
		return 0, false

	default:
		return 0, false
	}
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

		// Handoff priority: if a handoff token exists for us, we win.
		if has, _ := m.etcdCli.CheckHandoff(ctx,
			req.GlockType, req.GlockNumber, m.nodeID); has {
			log.Printf("handoff priority: type=%d num=%d",
				req.GlockType, req.GlockNumber)
			m.etcdCli.DeleteHandoff(ctx, req.GlockType, req.GlockNumber)
			// Fall through to normal acquire; the key should be free.
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
			m.startBastWatch(ctx, req.GlockType, req.GlockNumber, mode)
		} else if holderNodeID == m.nodeID {
			// Self-contention: we hold this lock and want a different mode.
			// Release everything (EX key + any SH sub-key) and reacquire.
			log.Printf("lock self-contention: type=%d num=%d holder=%s→%s",
				req.GlockType, req.GlockNumber, holderMode, mode)
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
			// Also clean SH sub-key in case we previously held SH.
			m.etcdCli.ReleaseSHLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID)
			// Retry once after releasing.
			g2, r2, _, _, e2 := m.etcdCli.AcquireLock(ctx,
				req.GlockType, req.GlockNumber, m.nodeID, mode)
			if e2 != nil {
				log.Printf("self-contention reacquire error: %v", e2)
				m.sendDeny(req.RequestID, protocol.DenyReasonError)
				return
			}
			if g2 {
				m.sendGrant(req.RequestID, req.RequestedMode, r2)
				m.startBastWatch(ctx, req.GlockType, req.GlockNumber, mode)
			} else {
				m.sendWait(req.RequestID)
				go m.watchAndRetry(ctx, req)
			}
		} else {
			target, ok := compatibleBastMode(holderMode, req.RequestedMode)
			if ok {
				log.Printf("lock contended: holder=%s requester=%d → bast target=%d",
					holderMode, req.RequestedMode, target)
				if err := m.etcdCli.RequestBast(ctx,
					req.GlockType, req.GlockNumber, target, m.nodeID); err != nil {
					log.Printf("bast request error: %v", err)
				}
			} else {
				log.Printf("lock contended (no downgrade path): holder=%s requester=%d",
					holderMode, req.RequestedMode)
			}
			m.sendWait(req.RequestID)
			go m.watchAndRetry(ctx, req)
		}
	}()
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

	waiter := hl.waiterNodeID
	if waiter != "" && waiter != m.nodeID {
		// Atomic handoff: delete primary key and reserve for waiter.
		// Also clean up SH sub-key if we held in SH mode.
		if err := m.etcdCli.HandoffRelease(ctx,
			lockType, lockNumber, waiter); err != nil {
			log.Printf("handoff release error: %v", err)
		} else {
			log.Printf("handoff: type=%d num=%d → %s",
				lockType, lockNumber, waiter)
		}
		if hl.mode != "EX" {
			m.etcdCli.ReleaseSHLock(ctx, lockType, lockNumber, m.nodeID)
		}
	} else {
		if hl.mode == "EX" {
			m.etcdCli.ReleaseLock(ctx, lockType, lockNumber)
		} else {
			m.etcdCli.ReleaseSHLock(ctx, lockType, lockNumber, m.nodeID)
		}
	}
	m.etcdCli.DeleteBastRequest(ctx, lockType, lockNumber)
	log.Printf("released lock type=%d num=%d mode=%s",
		lockType, lockNumber, hl.mode)
}

func (m *Manager) startBastWatch(parentCtx context.Context,
	lockType uint32, lockNumber uint64, mode string) {

	ctx, cancel := context.WithCancel(parentCtx)
	mapKey := lockMapKey(lockType, lockNumber)

	m.mu.Lock()
	if prev, ok := m.heldLocks[mapKey]; ok {
		prev.cancel()
	}
	m.heldLocks[mapKey] = &heldLock{cancel: cancel, mode: mode}
	m.mu.Unlock()

	go func() {
		defer cancel()
		ch := m.etcdCli.WatchLockBast(ctx, lockType, lockNumber)
		for resp := range ch {
			if resp.Err() != nil {
				return
			}
			for _, ev := range resp.Events {
				if ev.Type != 0 {
					continue
				}
				val := string(ev.Kv.Value)
				// Format: "target_mode,waiter_node_id"
				parts := strings.SplitN(val, ",", 2)
				targetMode, err := strconv.ParseUint(parts[0], 10, 32)
				if err != nil {
					continue
				}
				waiterID := ""
				if len(parts) > 1 {
					waiterID = parts[1]
				}
				log.Printf("bast request: type=%d num=%d target=%d waiter=%s",
					lockType, lockNumber, targetMode, waiterID)

				// Store waiter so releaseHeldLock can do atomic handoff.
				if waiterID != "" {
					m.mu.Lock()
					if hl, ok := m.heldLocks[mapKey]; ok {
						hl.waiterNodeID = waiterID
					}
					m.mu.Unlock()
				}

				m.sendBast(lockType, lockNumber, uint32(targetMode))
				break
			}
		}
	}()
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

		jid, err := m.etcdCli.AssignJournal(ctx,
			m.nodeID, protocol.MaxJournals)
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

				if has, _ := m.etcdCli.CheckHandoff(ctx,
					req.GlockType, req.GlockNumber, m.nodeID); has {
					log.Printf("handoff priority (retry): type=%d num=%d",
						req.GlockType, req.GlockNumber)
					m.etcdCli.DeleteHandoff(ctx,
						req.GlockType, req.GlockNumber)
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
					m.startBastWatch(ctx, req.GlockType, req.GlockNumber, mode)
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
		RequestID:    requestID,
		GrantedMode:  mode,
		EtcdRevision: revision,
	}); err != nil {
		log.Printf("send grant error: %v", err)
	}
}

func (m *Manager) sendDeny(requestID uint64, reason uint32) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendLockDeny(protocol.LockDeny{
		RequestID: requestID,
		Reason:    reason,
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

func (m *Manager) sendBast(lockType uint32, lockNumber uint64, targetMode uint32) {
	if m.nlSrv == nil {
		return
	}
	if err := m.nlSrv.SendBast(protocol.BastNotification{
		GlockNumber: lockNumber,
		GlockType:   lockType,
		TargetMode:  targetMode,
	}); err != nil {
		log.Printf("send bast error: %v", err)
	} else {
		log.Printf("sent bast: type=%d num=%d target=%d",
			lockType, lockNumber, targetMode)
	}
}

func (m *Manager) sendMountResponse(requestID uint64, jid int32) {
	if m.nlSrv == nil {
		log.Printf("mount response NOT SENT: netlink server is nil")
		return
	}
	log.Printf("sending mount response: jid=%d via netlink", jid)
	if err := m.nlSrv.SendMountResponse(protocol.MountResponse{
		RequestID: requestID,
		JID:       jid,
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
