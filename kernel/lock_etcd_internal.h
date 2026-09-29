/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LOCK_ETCD_INTERNAL_H
#define _LOCK_ETCD_INTERNAL_H
#include <linux/types.h>
#include <linux/spinlock.h>
#include <linux/timer.h>
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
#define LETCD_WAIT_TIMEOUT  (30 * HZ)

struct letcd_pending_entry {
	u64 request_id;
	struct gfs2_glock *gl;
	unsigned long wait_start;  /* jiffies when WAIT received, 0 = not waiting */
	struct hlist_node node;
};

extern spinlock_t letcd_pending_lock;
extern DECLARE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
extern struct timer_list letcd_wait_timeout_timer;
extern atomic64_t letcd_req_counter;
extern struct sock *letcd_nl_sk;
extern struct letcd_mount_context letcd_mount_ctx;
extern const struct lm_lockops letcd_ops;

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl);
struct gfs2_glock *letcd_pending_remove(u64 request_id);
struct gfs2_glock *letcd_pending_find(u64 request_id);
void letcd_pending_mark_wait(u64 request_id);
void letcd_bast_insert(u32 glock_type, u64 glock_number, struct gfs2_glock *gl);
void letcd_bast_remove(u32 glock_type, u64 glock_number);
struct gfs2_glock *letcd_bast_lookup(u32 glock_type, u64 glock_number);
s64  letcd_revision_swap(struct gfs2_glock *gl, s64 revision);
int  letcd_mount(struct gfs2_sbd *sdp, const char *table);
void letcd_first_done(struct gfs2_sbd *sdp);
void letcd_recovery_result(struct gfs2_sbd *sdp,
			   unsigned int jid, unsigned int result);
void letcd_unmount(struct gfs2_sbd *sdp);
void letcd_withdraw(struct gfs2_sbd *sdp);
void letcd_put_lock(struct gfs2_glock *gl);
int  letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
		unsigned int flags);
void letcd_cancel(struct gfs2_glock *gl);
int  lock_etcd_init_module(void);
void lock_etcd_exit_module(void);
int  letcd_netlink_init(void);
void letcd_netlink_exit(void);
int  letcd_nl_send_msg(int msg_type, const void *payload, size_t len);

struct letcd_mount_context {
	struct completion mount_done;
	int mount_jid;
	int mount_error;
	u64 mount_request_id;
	s64 mount_epoch;      /* cluster/epoch at mount time */
	spinlock_t lock;
};
#endif
