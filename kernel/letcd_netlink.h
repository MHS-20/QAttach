/*
 * letcd_netlink.h — shared Netlink protocol between lock_etcd.ko and cluster-agent.
 * Included by both C (kernel module) and Go (via cgo if needed, or kept in sync manually).
 */
#ifndef _LETCD_NETLINK_H
#define _LETCD_NETLINK_H

#include <linux/types.h>

#define LETCD_NETLINK_FAMILY  31
#define LETCD_MAX_PAYLOAD     256
#define LETCD_LVB_SIZE        32  /* GDLM_LVB_SIZE */

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
#define LETCD_MSG_CANCEL      12  /* kernel → agent: cancel a waiting request */
#define LETCD_MSG_RECOVERY_DONE 13 /* kernel → agent: journal replay finished */

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
#define LETCD_DENY_DEADLOCK    5   /* conversion deadlock — drop to UN and retry */
#define LETCD_DENY_CANCELED    6   /* request canceled by lm_cancel */
#define LETCD_DENY_TRY_AGAIN   7   /* TRY request not grantable now */

/* Request flags — must match GFS2 LM_FLAG_* */
#define LETCD_FLAG_TRY         0x0001
#define LETCD_FLAG_TRY_1CB     0x0002
#define LETCD_FLAG_NOEXP       0x0004  /* grantable during recovery */

/* lvb_valid on a request or release means the sender held EX and lvb is
 * the value block to publish, as DLM does on an EX down-conversion or unlock.
 * On a grant it means lvb is the current value; otherwise the receiver must
 * treat its value block as invalid. */
struct letcd_lock_req {
	__u64 request_id;
	__u64 glock_number;
	__u32 glock_type;
	__u32 requested_mode;
	__u32 lvb_valid;
	__u32 flags;            /* LM_FLAG_TRY / LM_FLAG_TRY_1CB / LM_FLAG_NOEXP */
	__u8  lvb[LETCD_LVB_SIZE];
};

struct letcd_lock_grant {
	__u64 request_id;
	__u32 granted_mode;
	__u32 lvb_valid;
	__s64 etcd_revision;    /* fencing token */
	__u8  lvb[LETCD_LVB_SIZE];
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
	__u32 lvb_valid;
	__u8  lvb[LETCD_LVB_SIZE];
};

struct letcd_lock_cancel {
	__u64 glock_number;
	__u32 glock_type;
	__u32 pad;
};

struct letcd_recovery_ok {
	__u32 jid;
};

/* result is GFS2's LM_RD_SUCCESS (309) or LM_RD_GAVEUP (308). */
struct letcd_recovery_done {
	__u32 jid;
	__u32 result;
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
