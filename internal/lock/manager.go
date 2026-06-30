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

// heldLock tracks a lock held by this node.
type heldLock struct {
	cancel context.CancelFunc
	mode   string // etcd mode: EX, PR, CW
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
	heldLocks map[string]*heldLock // key: "type/number"
}

// NewManager creates a lock manager.
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

// SetNetlink sets the netlink server reference.
func (m *Manager) SetNetlink(srv *netlink.Server) {
	m.nlSrv = srv
}

func lockMapKey(lockType uint32, lockNumber uint64) string {
	return strconv.FormatUint(uint64(lockType), 10) + "/" +
		strconv.FormatUint(lockNumber, 10)
}

// ---- lock compatibility ----

// etcdModeToNum maps etcd mode strings back to GFS2 LM_ST_* values.
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

// compatibleBastMode returns the target mode for a BAST demotion, or 0
// if no compatible downgrade exists.
//
// Based on GFS2 lock compatibility matrix:
//
//	Holder↓ Requester→  EX      DF      SH
//	EX                  ✗       ✗       →SH
//	DF                  ✗       ✓       →SH
//	SH                  ✗       ✗       ✓
//
// EX→SH is always valid per the mode matrix; the holder's GFS2 decides
// whether to comply.  The bast watch stays alive to retry if the holder
// reacquires EX.
func compatibleBastMode(holderEtcdMode string, requesterMode uint32) uint32 {
	h := etcdModeToNum(holderEtcdMode)
	r := requesterMode

	if h == protocol.LockModeShared && r == protocol.LockModeShared {
		return 0 // already compatible
	}

	switch h {
	case protocol.LockModeExclusive:
		if r == protocol.LockModeShared {
			return protocol.LockModeShared // EX → SH
		}
		return 0 // EX can't demote for EX or DF requester

	case protocol.LockModeDeferred:
		if r == protocol.LockModeShared {
			return protocol.LockModeShared // DF → SH
		}
		if r == protocol.LockModeExclusive {
			return protocol.LockModeUnlocked // DF must release for EX
		}
		return 0

	case protocol.LockModeShared:
		if r == protocol.LockModeExclusive || r == protocol.LockModeDeferred {
			return protocol.LockModeUnlocked // SH must release for EX/DF
		}
		return 0

	default:
		return 0
	}
}

// ---- lock request handling ----

// HandleLockRequest processes a lock request from the kernel module.
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

		granted, rev, holderMode, err := m.etcdCli.AcquireLock(ctx,
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
		} else {
			// Only request bast if a compatible downgrade exists.
			target := compatibleBastMode(holderMode, req.RequestedMode)
			if target != 0 {
				log.Printf("lock contended: holder=%s requester=%d → bast target=%d",
					holderMode, req.RequestedMode, target)
				if err := m.etcdCli.RequestBast(ctx,
					req.GlockType, req.GlockNumber, target); err != nil {
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

	if ok {
		hl.cancel()
		if hl.mode == "EX" {
			m.etcdCli.ReleaseLock(ctx, lockType, lockNumber)
		} else {
			m.etcdCli.ReleaseSHLock(ctx, lockType, lockNumber, m.nodeID)
		}
		m.etcdCli.DeleteBastRequest(ctx, lockType, lockNumber)
		log.Printf("released lock type=%d num=%d mode=%s",
			lockType, lockNumber, hl.mode)
	}
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
				if ev.Type != 0 { // not PUT
					continue
				}
				targetMode, err := strconv.ParseUint(
					string(ev.Kv.Value), 10, 32)
				if err != nil {
					continue
				}
				log.Printf("bast request: type=%d num=%d target=%d",
					lockType, lockNumber, targetMode)
				m.sendBast(lockType, lockNumber, uint32(targetMode))
				// Keep watch alive — GFS2 may reacquire and need another BAST.
				// The bast request key is cleaned up in releaseHeldLock.
				break // one BAST per event batch; continue watching
			}
		}
	}()
}

// HandleLockRelease processes a lock release from the kernel module.
func (m *Manager) HandleLockRelease(req protocol.LockRelease) {
	ctx := context.Background()
	m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
}

// HandleUnmount cleans up when the filesystem unmounts.
func (m *Manager) HandleUnmount() {
	log.Printf("filesystem unmounting — releasing all resources")
}

// HandleMountRequest handles the initial mount request from kernel module.
// Journal ID is assigned via etcd CAS to avoid collisions across nodes.
func (m *Manager) HandleMountRequest(req protocol.MountRequest) {
	go func() {
		ctx := context.Background()

		jid, err := m.etcdCli.AssignJournal(ctx,
			m.nodeID, protocol.MaxJournals)
		if err != nil {
			log.Printf("journal assignment error: %v", err)
			jid = -1 // error sentinel
		}
		if jid < 0 {
			log.Printf("mount request: no free journal slots")
			m.sendMountResponse(req.RequestID, -1) // error
			return
		}

		m.mountJID = jid
		log.Printf("mount request: cluster=%s, assigned jid=%d",
			cstring(req.FilesystemName[:]), jid)

		m.sendMountResponse(req.RequestID, jid)
	}()
}

// watchAndRetry watches for lock release and retries acquisition.
func (m *Manager) watchAndRetry(ctx context.Context, req protocol.LockRequest) {
	watchCh := m.etcdCli.WatchLockKey(ctx, req.GlockType, req.GlockNumber)
	for resp := range watchCh {
		for _, ev := range resp.Events {
			if ev.Type == 1 { // DELETE
				mode := protocol.LockModeToEtcd(req.RequestedMode)
				granted, rev, _, err := m.etcdCli.AcquireLock(ctx,
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
