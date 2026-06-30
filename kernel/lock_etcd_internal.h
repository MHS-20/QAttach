/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LOCK_ETCD_INTERNAL_H
#define _LOCK_ETCD_INTERNAL_H
#include <linux/types.h>
#include <linux/spinlock.h>
#include <linux/hashtable.h>
#include <linux/completion.h>
#include <linux/atomic.h>
#include <linux/netlink.h>
#include <net/netlink.h>
#include <linux/gfs2_ondisk.h>
#include <linux/list.h>
#include "incore.h"
#include "glock.h"
#include "letcd_netlink.h"

#define LETCD_PENDING_BITS  8

/* Ordered lock queue entry — prevents deadlock by serialising
 * lock acquisition per node into a consistent global order.
 * Entries are sorted by (glock_type << 56 | glock_number).
 */
struct letcd_ordered_entry {
	struct list_head  list;
	u64               order_key;
	struct completion done;
	bool              completed;
};

struct letcd_pending_entry {
	u64 request_id;
	struct gfs2_glock *gl;
	struct hlist_node node;
	struct letcd_ordered_entry ordered;
};

extern spinlock_t letcd_pending_lock;
extern DECLARE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
extern atomic64_t letcd_req_counter;
extern struct sock *letcd_nl_sk;
extern struct letcd_mount_context letcd_mount_ctx;
extern const struct lm_lockops letcd_ops;

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl,
			  u32 glock_type, u64 glock_number);
struct gfs2_glock *letcd_pending_remove(u64 request_id);
struct letcd_pending_entry *letcd_pending_lookup(u64 request_id);
void letcd_bast_insert(u32 glock_type, u64 glock_number, struct gfs2_glock *gl);
void letcd_bast_remove(u32 glock_type, u64 glock_number);
struct gfs2_glock *letcd_bast_lookup(u32 glock_type, u64 glock_number);
void letcd_revision_set(struct gfs2_glock *gl, s64 revision);
s64  letcd_revision_get(struct gfs2_glock *gl);
void letcd_revision_clear(struct gfs2_glock *gl);
int  letcd_netlink_init(void);
void letcd_netlink_exit(void);
int  letcd_nl_send_msg(int msg_type, const void *payload, size_t len);

/* Ordered lock queue for deadlock prevention. */
void letcd_ordered_enqueue(struct letcd_ordered_entry *e,
			   u32 glock_type, u64 glock_number);
void letcd_ordered_drain(struct letcd_ordered_entry *e);
void letcd_ordered_complete(struct letcd_ordered_entry *e);

struct letcd_mount_context {
	struct completion mount_done;
	int mount_jid;
	int mount_error;
	u64 mount_request_id;
	spinlock_t lock;
};
#endif
