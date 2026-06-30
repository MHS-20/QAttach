package protocol

// Netlink family — custom protocol between lock_etcd and cluster-agent.
const (
	LetcdNetlinkFamily = 31
	LetcdMaxPayload    = 256
)

// Message types — kernel↔agent.
const (
	MsgLockReq    = 1 // kernel → agent: request glock
	MsgLockGrant  = 2 // agent → kernel: granted + fencing token
	MsgLockDeny   = 3 // agent → kernel: denied (contended or stale)
	MsgLockWait   = 4 // agent → kernel: queued, will notify on release
	MsgBast       = 5 // agent → kernel: demote callback (blocking AST)
	MsgLockRel    = 6 // kernel → agent: release glock
	MsgRecoveryOk = 7 // agent → kernel: node fenced, journal replay safe
	MsgUnmount    = 8 // kernel → agent: filesystem unmounting
	MsgMountReq   = 9  // kernel → agent: mount request (needs jid)
	MsgMountResp  = 10 // agent → kernel: mount response with jid
	MsgRegister   = 11 // agent → kernel: register PID for unicast replies
)

// LockRequest sent from kernel to agent requesting a glock.
type LockRequest struct {
	RequestID     uint64
	GlockNumber   uint64
	GlockType     uint32
	RequestedMode uint32
}

// LockGrant sent from agent to kernel on successful acquisition.
// PadGrant ensures 24-byte size matching C struct letcd_lock_grant
// (C inserts 4 bytes padding after granted_mode to align etcd_revision to 8).
type LockGrant struct {
	RequestID    uint64
	GrantedMode  uint32
	PadGrant     [4]byte
	EtcdRevision int64 // fencing token — store in glock private data
}

// LockDeny sent from agent to kernel when lock cannot be granted.
// PadDeny ensures 16-byte size matching C struct letcd_lock_deny
// (C adds 4 bytes trailing padding to align struct to 8).
type LockDeny struct {
	RequestID uint64
	Reason    uint32
	PadDeny   [4]byte
}

// LockWait sent from agent to kernel when lock is contended.
type LockWait struct {
	RequestID uint64
}

// BastNotification sent from agent to kernel to demote a held lock.
type BastNotification struct {
	GlockNumber uint64
	GlockType   uint32
	TargetMode  uint32 // mode to demote to (typically UNLOCKED)
}

// LockRelease sent from kernel to agent when a glock is released.
type LockRelease struct {
	GlockNumber uint64
	GlockType   uint32
}

// RecoveryOk sent from agent to kernel after fencing completes.
type RecoveryOk struct {
	JID uint32 // journal ID of the recovered node
}

// MountRequest sent from kernel to agent during lm_mount.
type MountRequest struct {
	RequestID    uint64
	ClusterName  [32]byte
	FilesystemName [32]byte
}

// MountResponse sent from agent to kernel with assigned journal ID.
// PadMnt ensures 16-byte size matching C struct letcd_mount_resp
// (Go binary.Write omits trailing padding; C adds 4 bytes to align to 8).
type MountResponse struct {
	RequestID uint64
	JID       int32 // negative on error
	PadMnt    [4]byte
}

// Deny reasons.
const (
	DenyReasonContended = 1 // another node holds the lock
	DenyReasonStale     = 2 // fencing token mismatch — cache is stale
	DenyReasonError     = 3 // internal error
)
