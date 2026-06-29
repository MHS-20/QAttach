/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * lock_etcd_internal.h — shared internal state.
 *
 * Includes GFS2 headers from the kernel source tree (available via
 * -I$(srctree)/fs/gfs2 in Kbuild).  Falls back to compat shims
 * when building outside the kernel tree.
 */

#ifndef _LOCK_ETCD_INTERNAL_H
#define _LOCK_ETCD_INTERNAL_H

#include <linux/types.h>
#include <linux/spinlock.h>
#include <linux/hashtable.h>
#include <linux/completion.h>
#include <linux/atomic.h>
#include <linux/netlink.h>

#ifdef __KERNEL__
#include "incore.h"
#include "lm_interface.h"
#else
#include "gfs2_compat.h"
#endif

#include "letcd_netlink.h"

/* ------------------------------------------------------------------ */
/* Pending request tracking                                            */
/* ------------------------------------------------------------------ */

#define LETCD_PENDING_BITS  8

struct letcd_pending_entry {
	u64                 request_id;
	struct gfs2_glock   *gl;
	struct hlist_node   node;
};

extern spinlock_t letcd_pending_lock;
extern DECLARE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
extern atomic64_t letcd_req_counter;

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl);
struct gfs2_glock *letcd_pending_remove(u64 request_id);

/* ------------------------------------------------------------------ */
/* BAST glock lookup table                                             */
/* ------------------------------------------------------------------ */

void letcd_bast_insert(u32 glock_type, u64 glock_number,
		       struct gfs2_glock *gl);
void letcd_bast_remove(u32 glock_type, u64 glock_number);
struct gfs2_glock *letcd_bast_lookup(u32 glock_type, u64 glock_number);

/* ------------------------------------------------------------------ */
/* Per-glock revision tracking (fencing token)                         */
/* ------------------------------------------------------------------ */

void letcd_revision_set(struct gfs2_glock *gl, s64 revision);
s64  letcd_revision_get(struct gfs2_glock *gl);
void letcd_revision_clear(struct gfs2_glock *gl);

/* ------------------------------------------------------------------ */
/* Netlink                                                             */
/* ------------------------------------------------------------------ */

extern struct sock *letcd_nl_sk;

int  letcd_netlink_init(void);
void letcd_netlink_exit(void);
int  letcd_nl_send_msg(int msg_type, const void *payload, size_t len);

/* ------------------------------------------------------------------ */
/* Mount                                                               */
/* ------------------------------------------------------------------ */

struct letcd_mount_context {
	struct completion   mount_done;
	int                 mount_jid;
	int                 mount_error;
	u64                 mount_request_id;
	spinlock_t          lock;
};

extern struct letcd_mount_context letcd_mount_ctx;

#endif /* _LOCK_ETCD_INTERNAL_H */
