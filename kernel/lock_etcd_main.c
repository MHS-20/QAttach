/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * lock_etcd_main.c — lm_lockops registration.
 *
 * Built as part of gfs2.ko.  Initialized/cleaned up from GFS2's
 * main.c (patched at build time by scripts/kernel/patch-kernel.sh).
 */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include "lock_etcd_internal.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("QAttach");
MODULE_DESCRIPTION("GFS2 locking protocol backed by etcd");

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

const match_table_t letcd_tokens = {
	{ Opt_err, NULL },
};

const struct lm_lockops letcd_ops = {
	.lm_proto_name      = "lock_etcd",
	.lm_mount           = letcd_mount,
	.lm_first_done      = letcd_first_done,
	.lm_recovery_result = letcd_recovery_result,
	.lm_unmount         = letcd_unmount,
	.lm_withdraw        = letcd_withdraw,
	.lm_put_lock        = letcd_put_lock,
	.lm_lock            = letcd_lock,
	.lm_cancel          = letcd_cancel,
	.lm_tokens          = &letcd_tokens,
};
EXPORT_SYMBOL_GPL(letcd_ops);

int __init lock_etcd_init_module(void)
{
	spin_lock_init(&letcd_pending_lock);
	hash_init(letcd_pending_table);
	atomic64_set(&letcd_req_counter, 0);
	spin_lock_init(&letcd_mount_ctx.lock);
	init_completion(&letcd_mount_ctx.mount_done);
	letcd_netlink_init();
	pr_info("lock_etcd protocol registered\n");
	return 0;
}

void __exit lock_etcd_exit_module(void)
{
	letcd_netlink_exit();
}
