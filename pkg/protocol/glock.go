package protocol

// Glock types — must match GFS2 lm_lockname types exactly.
const (
	LockTypeNondisk = 0
	LockTypeInode   = 1
	LockTypeRgrp    = 2
	LockTypeMeta    = 3
	LockTypeIopen   = 4
	LockTypeFlock   = 5
	LockTypePlock   = 6
	LockTypeQuota   = 7
	LockTypeJournal = 8
)

// Lock modes — must match GFS2 LM_ST_* constants exactly.
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
