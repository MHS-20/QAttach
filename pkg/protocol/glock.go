package protocol

// Glock types — must match GFS2 lm_lockname types exactly.
// GFS2's LM_TYPE_* enum:
//   LM_TYPE_RESERVED = 0, LM_TYPE_NONDISK = 1, LM_TYPE_INODE = 2,
//   LM_TYPE_RGRP = 3, LM_TYPE_META = 4, LM_TYPE_IOPEN = 5,
//   LM_TYPE_FLOCK = 6, LM_TYPE_PLOCK = 7, LM_TYPE_QUOTA = 8,
//   LM_TYPE_JOURNAL = 9
const (
	LockTypeReserved = 0
	LockTypeNondisk  = 1 // superblock uses this (num=0)
	LockTypeInode    = 2
	LockTypeRgrp     = 3
	LockTypeMeta     = 4
	LockTypeIopen    = 5
	LockTypeFlock    = 6
	LockTypePlock    = 7
	LockTypeQuota    = 8
	LockTypeJournal  = 9
)

// Lock modes — must match GFS2 LM_ST_* constants exactly.
// GFS2 glock.h: LM_ST_UNLOCKED=0, LM_ST_EXCLUSIVE=1, LM_ST_DEFERRED=2, LM_ST_SHARED=3
const (
	LockModeUnlocked  = 0
	LockModeExclusive = 1
	LockModeDeferred  = 2
	LockModeShared    = 3
)

// etcd lock mode representation.
const (
	EtcdModeEX = "EX" // exclusive — one holder
	EtcdModePR = "PR" // protected read — multiple concurrent shared holders
	EtcdModeCW = "CW" // concurrent write — direct I/O
)

// LockModeToEtcd maps GFS2 lock modes to etcd lock modes.
func LockModeToEtcd(mode uint32) string {
	switch mode {
	case LockModeExclusive:
		return EtcdModeEX
	case LockModeShared:
		return EtcdModePR
	case LockModeDeferred:
		return EtcdModeCW
	default:
		return ""
	}
}

// LockModeName returns a human-readable name for a lock mode.
func LockModeName(mode uint32) string {
	switch mode {
	case LockModeUnlocked:
		return "UN"
	case LockModeExclusive:
		return "EX"
	case LockModeDeferred:
		return "DF"
	case LockModeShared:
		return "SH"
	default:
		return "??"
	}
}
