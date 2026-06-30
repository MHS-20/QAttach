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

// heldLock tracks a lock held by this node so we can clean up BAST watches.
type heldLock struct {
	cancel context.CancelFunc
	mode   string // EX or PR (=SH in etcd terms)
}

// Manager handles glock requests from the kernel module via etcd.
type Manager struct {
	etcdCli *etcd.Client
	nlSrv   *netlink.Server
	nodeID  string

	mu           sync.Mutex
	mountReqs    map[uint64]chan int32
	mountJID     int32
	nextJID      int32
	heldLocks    map[string]*heldLock // key: "type/number"
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

// SetNetlink sets the netlink server reference (used after server init).
func (m *Manager) SetNetlink(srv *netlink.Server) {
	m.nlSrv = srv
}

// lockKey builds the map key for tracking held locks.
func lockMapKey(lockType uint32, lockNumber uint64) string {
	return strconv.FormatUint(uint64(lockType), 10) + "/" +
		strconv.FormatUint(lockNumber, 10)
}

// HandleLockRequest processes a lock request from the kernel module.
func (m *Manager) HandleLockRequest(req protocol.LockRequest) {
	go func() {
		ctx := context.Background()

		log.Printf("lock request: id=%d type=%d num=%d mode=%d",
			req.RequestID, req.GlockType, req.GlockNumber, req.RequestedMode)

		mode := protocol.LockModeToEtcd(req.RequestedMode)
		if mode == "" {
			// UNLOCKED → release the lock.
			m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
			return
		}

		granted, rev, err := m.etcdCli.AcquireLock(ctx,
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
			// Contended — signal the holder via bast, then wait.
			targetMode := compatibleBastMode(req.RequestedMode)
			if err := m.etcdCli.RequestBast(ctx,
				req.GlockType, req.GlockNumber, targetMode); err != nil {
				log.Printf("bast request error: %v", err)
			}
			m.sendWait(req.RequestID)
			go m.watchAndRetry(ctx, req)
		}
	}()
}

// releaseHeldLock cleans up a held lock, cancels its bast watch,
// and removes it from etcd.
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

// startBastWatch spawns a goroutine that watches for BAST requests on
// a lock we hold.  When a BAST request arrives, we send a BAST to the
// kernel so GFS2 can demote the lock.
func (m *Manager) startBastWatch(parentCtx context.Context,
	lockType uint32, lockNumber uint64, mode string) {

	ctx, cancel := context.WithCancel(parentCtx)
	mapKey := lockMapKey(lockType, lockNumber)

	m.mu.Lock()
	// Cancel previous watch if re-acquiring the same lock.
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
				return // context cancelled or error
			}
			for _, ev := range resp.Events {
				if ev.Type != 0 { // PUT
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
				// Clean up the bast key (the requester will retry).
				m.etcdCli.DeleteBastRequest(ctx,
					lockType, lockNumber)
				return // one BAST is enough; GFS2 will demote
			}
		}
	}()
}

// compatibleBastMode returns a target mode that is compatible with
// the requested mode.  For SH requests, ask the EX holder to
// downgrade to SH.  For EX requests, ask any holder to release.
func compatibleBastMode(requestedMode uint32) uint32 {
	switch requestedMode {
	case protocol.LockModeShared:
		return protocol.LockModeShared
	default:
		return protocol.LockModeShared // conservative: request SH
	}
}

// HandleLockRelease processes a lock release from the kernel module.
func (m *Manager) HandleLockRelease(req protocol.LockRelease) {
	ctx := context.Background()
	m.releaseHeldLock(ctx, req.GlockType, req.GlockNumber)
}

// HandleUnmount cleans up when the filesystem unmounts.
func (m *Manager) HandleUnmount() {
	log.Printf("filesystem unmounting — releasing all resources")
	// etcd session will be closed and delete all lock keys automatically.
}

// HandleMountRequest handles the initial mount request from kernel module.
func (m *Manager) HandleMountRequest(req protocol.MountRequest) {
	go func() {
		m.mu.Lock()
		jid := m.nextJID
		m.nextJID++
		m.mu.Unlock()

		clusterName := cstring(req.ClusterName[:])
		_ = clusterName // used for membership context

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
				// Lock released — retry acquisition.
				mode := protocol.LockModeToEtcd(req.RequestedMode)
				granted, rev, err := m.etcdCli.AcquireLock(ctx,
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

// cstring extracts a null-terminated string from a fixed-size byte array.
func cstring(b []byte) string {
	for i, v := range b {
		if v == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}
