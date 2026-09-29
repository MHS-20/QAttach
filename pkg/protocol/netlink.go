package protocol

// Netlink family — custom protocol between lock_etcd and cluster-agent.
const (
	LetcdNetlinkFamily = 31
	LetcdMaxPayload    = 256
	LetcdLvbSize       = 32 // GDLM_LVB_SIZE
)

// Message types — kernel↔agent.
const (
	MsgLockReq    = 1  // kernel → agent: request glock
	MsgLockGrant  = 2  // agent → kernel: granted + fencing token
	MsgLockDeny   = 3  // agent → kernel: denied (contended or stale)
	MsgLockWait   = 4  // agent → kernel: queued, will notify on release
	MsgBast       = 5  // agent → kernel: demote callback (blocking AST)
	MsgLockRel    = 6  // kernel → agent: release glock
	MsgRecoveryOk = 7  // agent → kernel: node fenced, journal replay safe
	MsgUnmount    = 8  // kernel → agent: filesystem unmounting
	MsgMountReq   = 9  // kernel → agent: mount request (needs jid)
	MsgMountResp  = 10 // agent → kernel: mount response with jid
	MsgRegister   = 11 // agent → kernel: register PID for unicast replies
	MsgCancel     = 12 // kernel → agent: cancel a waiting request
)

// LockRequest sent from kernel to agent requesting a glock.
type LockRequest struct {
	RequestID     uint64
	GlockNumber   uint64
	GlockType     uint32
	RequestedMode uint32
	LvbValid      uint32 // Lvb holds the value block to publish (sender held EX)
	Flags         uint32 // FlagTry / FlagTry1CB
	Lvb           [LetcdLvbSize]byte
}

// LockGrant sent from agent to kernel on successful acquisition.
// LvbValid=0 tells the kernel to zero its copy of the value block.
type LockGrant struct {
	RequestID    uint64
	GrantedMode  uint32
	LvbValid     uint32
	EtcdRevision int64 // fencing token — store in glock private data
	Lvb          [LetcdLvbSize]byte
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
	LvbValid    uint32 // Lvb holds the value block to publish (sender held EX)
	Lvb         [LetcdLvbSize]byte
}

// LockCancel sent from kernel to agent when GFS2 abandons a waiting request.
type LockCancel struct {
	GlockNumber uint64
	GlockType   uint32
	Pad         uint32
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

// MountResponse sent from agent to kernel with assigned journal ID and cluster epoch.
type MountResponse struct {
	RequestID uint64
	JID       int32 // negative on error
	PadMnt    [4]byte
	Epoch     int64 // cluster/epoch revision at mount time
}

// Request flags — GFS2 LM_FLAG_TRY / LM_FLAG_TRY_1CB.
const (
	FlagTry    = 0x0001 // fail instead of queueing
	FlagTry1CB = 0x0002 // as FlagTry, but first send the holders one BAST
)

// Deny reasons.
const (
	DenyReasonContended  = 1 // another node holds the lock
	DenyReasonStale      = 2 // fencing token mismatch — cache is stale
	DenyReasonError      = 3 // internal error
	DenyReasonStaleEpoch = 4 // node epoch < cluster epoch — node was fenced
	DenyReasonDeadlock   = 5 // conversion deadlock — kernel drops to UN and retries
	DenyReasonCanceled   = 6 // request canceled by lm_cancel
	DenyReasonTryAgain   = 7 // TRY request not grantable now
)
