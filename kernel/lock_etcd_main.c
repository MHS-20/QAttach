/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * lock_etcd_main.c — module init/exit, lm_lockops registration.
 */

#define pr_fmt(fmt) "lock_etcd: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

#include "lock_etcd_internal.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("QAttach");
MODULE_DESCRIPTION("GFS2 locking protocol backed by etcd");

/* ---- token table ---- */

enum { Opt_err };

static const match_table_t letcd_tokens = {
	{ Opt_err, NULL },
};

/* ---- forward declarations ---- */

static int  letcd_mount(struct gfs2_sbd *sdp, const char *table);
static void letcd_first_done(struct gfs2_sbd *sdp);
static void letcd_recovery_result(struct gfs2_sbd *sdp,
				  unsigned int jid, unsigned int result);
static void letcd_unmount(struct gfs2_sbd *sdp, bool clean);
static void letcd_put_lock(struct gfs2_glock *gl);
static void letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
		       unsigned int flags);
static void letcd_cancel(struct gfs2_glock *gl);

/* ---- lm_lockops ---- */

const struct lm_lockops letcd_ops = {
	.lm_proto_name      = "lock_etcd",
	.lm_mount           = letcd_mount,
	.lm_first_done      = letcd_first_done,
	.lm_recovery_result = letcd_recovery_result,
	.lm_unmount         = letcd_unmount,
	.lm_put_lock        = letcd_put_lock,
	.lm_lock            = letcd_lock,
	.lm_cancel          = letcd_cancel,
	.lm_tokens          = &letcd_tokens,
};

/* ---- init / exit ---- */

static int __init letcd_init(void)
{
	int ret;

	pr_info("initializing\n");

	spin_lock_init(&letcd_pending_lock);
	hash_init(letcd_pending_table);
	atomic64_set(&letcd_req_counter, 0);

	spin_lock_init(&letcd_mount_ctx.lock);
	init_completion(&letcd_mount_ctx.mount_done);

	ret = letcd_netlink_init();
	if (ret) {
		pr_err("netlink init failed: %d\n", ret);
		return ret;
	}

	ret = gfs2_register_lockproto(&letcd_ops);
	if (ret) {
		pr_err("register_lockproto failed: %d\n", ret);
		letcd_netlink_exit();
		return ret;
	}

	pr_info("registered\n");
	return 0;
}

static void __exit letcd_exit(void)
{
	pr_info("unregistering\n");
	gfs2_unregister_lockproto(&letcd_ops);
	letcd_netlink_exit();
}

module_init(letcd_init);
module_exit(letcd_exit);
