package lock

import (
	"context"
	"log"
	"sync"

	"github.com/polarity/qattach/internal/etcd"
	"github.com/polarity/qattach/internal/netlink"
	"github.com/polarity/qattach/pkg/protocol"
)

// Manager handles glock requests from the kernel module via etcd.
type Manager struct {
	etcdCli *etcd.Client
	nlSrv   *netlink.Server
	nodeID  string

	// Pending mount requests awaiting jid assignment.
	mu          sync.Mutex
	mountReqs   map[uint64]chan int32
	mountJID    int32
	nextJID     int32
}

// NewManager creates a lock manager.
func NewManager(ec *etcd.Client, nodeID string) *Manager {
	return &Manager{
		etcdCli:   ec,
		nodeID:    nodeID,
		mountReqs: make(map[uint64]chan int32),
		mountJID:  -1,
		nextJID:   0,
	}
}

// SetNetlink sets the netlink server reference (used after server init).
func (m *Manager) SetNetlink(srv *netlink.Server) {
	m.nlSrv = srv
}

// HandleLockRequest processes a lock request from the kernel module.
func (m *Manager) HandleLockRequest(req protocol.LockRequest) {
	go func() {
		ctx := context.Background()

		mode := protocol.LockModeToEtcd(req.RequestedMode)
		if mode == "" {
			// UNLOCKED → release the lock
			if err := m.etcdCli.ReleaseLock(ctx, req.GlockType, req.GlockNumber); err != nil {
				log.Printf("lock release error type=%d num=%d: %v", req.GlockType, req.GlockNumber, err)
			}
			return
		}

		granted, rev, err := m.etcdCli.AcquireLock(ctx,
			req.GlockType, req.GlockNumber, m.nodeID, mode)
		if err != nil {
			log.Printf("lock acquire error type=%d num=%d: %v", req.GlockType, req.GlockNumber, err)
			m.sendDeny(req.RequestID, protocol.DenyReasonError)
			return
		}

		if granted {
			m.sendGrant(req.RequestID, req.RequestedMode, rev)
		} else {
			// Contended — tell kernel to wait, then watch for release.
			m.sendWait(req.RequestID)
			go m.watchAndRetry(ctx, req)
		}
	}()
}

// HandleLockRelease processes a lock release from the kernel module.
func (m *Manager) HandleLockRelease(req protocol.LockRelease) {
	ctx := context.Background()
	if err := m.etcdCli.ReleaseLock(ctx, req.GlockType, req.GlockNumber); err != nil {
		log.Printf("lock release error type=%d num=%d: %v", req.GlockType, req.GlockNumber, err)
	}
}

// HandleUnmount cleans up when the filesystem unmounts.
func (m *Manager) HandleUnmount() {
	log.Printf("filesystem unmounting — releasing all resources")
	// etcd session will be closed and delete all lock keys automatically.
}

// HandleMountRequest handles the initial mount request from kernel module.
func (m *Manager) HandleMountRequest(req protocol.MountRequest) {
	go func() {
		ctx := context.Background()

		// Assign a journal ID (GFS2 handles the actual slot assignment).
		m.mu.Lock()
		jid := m.nextJID
		m.nextJID++
		m.mu.Unlock()

		// Register node in etcd.
		clusterName := cstring(req.ClusterName[:])
		_ = clusterName // used for membership context

		m.mountJID = jid

		log.Printf("mount request: cluster=%s, assigned jid=%d",
			cstring(req.FilesystemName[:]), jid)

		_ = ctx
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
				}
				return
			}
		}
	}
}

// sendGrant sends a lock grant response to the kernel module.
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

// sendDeny sends a lock denial to the kernel module.
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

// sendWait tells the kernel module to wait for lock contention to resolve.
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

// sendMountResponse sends the mount response with assigned journal ID.
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
