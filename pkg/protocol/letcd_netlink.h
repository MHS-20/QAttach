/*
 * letcd_netlink.h — shared Netlink protocol between lock_etcd.ko and cluster-agent.
 * Included by both C (kernel module) and Go (via cgo if needed, or kept in sync manually).
 */
#ifndef _LETCD_NETLINK_H
#define _LETCD_NETLINK_H

#include <linux/types.h>

#define LETCD_NETLINK_FAMILY  31
#define LETCD_MAX_PAYLOAD     256

/* Message types */
#define LETCD_MSG_LOCK_REQ    1   /* kernel → agent: request glock */
#define LETCD_MSG_LOCK_GRANT  2   /* agent → kernel: granted + fencing token */
#define LETCD_MSG_LOCK_DENY   3   /* agent → kernel: denied (contended or stale) */
#define LETCD_MSG_LOCK_WAIT   4   /* agent → kernel: queued, will notify on release */
#define LETCD_MSG_BAST        5   /* agent → kernel: demote callback */
#define LETCD_MSG_LOCK_REL    6   /* kernel → agent: release glock */
#define LETCD_MSG_RECOVERY_OK 7   /* agent → kernel: node fenced, journal replay safe */
#define LETCD_MSG_UNMOUNT     8   /* kernel → agent: filesystem unmounting */
#define LETCD_MSG_MOUNT_REQ   9   /* kernel → agent: mount request */
#define LETCD_MSG_MOUNT_RESP  10  /* agent → kernel: mount response with jid */
#define LETCD_MSG_REGISTER    11  /* agent → kernel: register PID for unicast */

/* Lock modes — must match GFS2 LM_ST_* exactly */
#define LETCD_LM_ST_UNLOCKED  0
#define LETCD_LM_ST_EXCLUSIVE 1
#define LETCD_LM_ST_DEFERRED  2
#define LETCD_LM_ST_SHARED    3

/* Deny reasons */
#define LETCD_DENY_CONTENDED   1
#define LETCD_DENY_STALE       2
#define LETCD_DENY_ERROR       3
#define LETCD_DENY_STALE_EPOCH 4   /* node epoch < cluster epoch — node was fenced */

struct letcd_lock_req {
	__u64 request_id;
	__u64 glock_number;
	__u32 glock_type;
	__u32 requested_mode;
};

struct letcd_lock_grant {
	__u64 request_id;
	__u32 granted_mode;
	__s64 etcd_revision;    /* fencing token */
};

struct letcd_lock_deny {
	__u64 request_id;
	__u32 reason;
};

struct letcd_lock_wait {
	__u64 request_id;
};

struct letcd_bast {
	__u64 glock_number;
	__u32 glock_type;
	__u32 target_mode;
};

struct letcd_lock_rel {
	__u64 glock_number;
	__u32 glock_type;
};

struct letcd_recovery_ok {
	__u32 jid;
};

struct letcd_mount_req {
	__u64 request_id;
	__u8  cluster_name[32];
	__u8  filesystem_name[32];
};

struct letcd_mount_resp {
	__u64 request_id;
	__s32 jid;              /* negative on error */
	__s64 epoch;            /* cluster/epoch revision at mount time */
};

#endif /* _LETCD_NETLINK_H */
