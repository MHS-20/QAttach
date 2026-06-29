package protocol

// etcd key schema (no leading / — etcd client strips it).
const (
	PrefixMembers = "cluster/members/"   // /cluster/members/{node_id}
	PrefixFencing = "cluster/fencing/"   // /cluster/fencing/{node_id}
	KeyEpoch      = "cluster/epoch"      // /cluster/epoch
	PrefixLocks   = "locks/glock/"       // /locks/glock/{type}/{number}
)

// MemberInfo stored in /cluster/members/{node_id}.
type MemberInfo struct {
	InstanceID string `json:"instance_id"`
	IP         string `json:"ip"`
	AZ         string `json:"az"`
}

// LockValue stored in /locks/glock/{type}/{number}.
type LockValue struct {
	OwnerNodeID string `json:"owner_node_id"`
	Mode        string `json:"mode"` // EX, PR, CW
}

// Session config.
const (
	SessionTTL = 15 // seconds
	KeepaliveInterval = 5 // seconds, must be < TTL/3 per etcd best practice
	FencingLeaseTTL = 60 // seconds, short TTL for fencing key
)
