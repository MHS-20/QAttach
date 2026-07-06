/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include <linux/delay.h>
#include <linux/string.h>
#include "lock_etcd_internal.h"

struct letcd_mount_context letcd_mount_ctx;
EXPORT_SYMBOL(letcd_mount_ctx);

int letcd_mount(struct gfs2_sbd *sdp, const char *table)
{
	struct lm_lockstruct *ls = &sdp->sd_lockstruct;
	struct letcd_mount_req req;
	int ret;
	unsigned long timeout;

	pr_info("mount: table=%s\n", table ? table : "(null)");

	reinit_completion(&letcd_mount_ctx.mount_done);
	letcd_mount_ctx.mount_jid = -1;
	letcd_mount_ctx.mount_error = 0;
	letcd_mount_ctx.mount_epoch = 0;
	letcd_mount_ctx.mount_request_id =
		atomic64_inc_return(&letcd_req_counter);

	memset(&req, 0, sizeof(req));
	req.request_id = letcd_mount_ctx.mount_request_id;

	if (table) {
		const char *colon = strchr(table, ':');
		if (colon) {
			size_t clen = (size_t)(colon - table);
			if (clen > sizeof(req.cluster_name) - 1)
				clen = sizeof(req.cluster_name) - 1;
			memcpy(req.cluster_name, table, clen);
		}
	}

	ret = letcd_nl_send_msg(LETCD_MSG_MOUNT_REQ, &req, sizeof(req));
	if (ret < 0) {
		pr_err("mount req send failed: %d\n", ret);
		return ret;
	}

	timeout = wait_for_completion_timeout(&letcd_mount_ctx.mount_done,
					      60 * HZ);
	if (!timeout) {
		pr_err("mount timed out\n");
		return -ETIMEDOUT;
	}
	if (letcd_mount_ctx.mount_error) {
		pr_err("mount denied: %d\n", letcd_mount_ctx.mount_error);
		return letcd_mount_ctx.mount_error;
	}

	ls->ls_jid = letcd_mount_ctx.mount_jid;
	ls->ls_first = 0;
	ls->ls_ops = &letcd_ops;

	clear_bit(SDF_NOJOURNALID, &sdp->sd_flags);
	smp_mb__after_atomic();
	wake_up_bit(&sdp->sd_flags, SDF_NOJOURNALID);

	pr_info("mount ok: jid=%d\n", ls->ls_jid);
	return 0;
}

void letcd_first_done(struct gfs2_sbd *sdp)
{
	pr_info("first mounter recovery done\n");
}

void letcd_recovery_result(struct gfs2_sbd *sdp, unsigned int jid,
			    unsigned int result)
{
	pr_info("recovery result: jid=%u result=%u\n", jid, result);
}

void letcd_unmount(struct gfs2_sbd *sdp)
{
	char dummy[4] = {0};
	pr_info("unmount\n");
	letcd_yield_cleanup();
	letcd_nl_send_msg(LETCD_MSG_UNMOUNT, dummy, sizeof(dummy));
}

void letcd_withdraw(struct gfs2_sbd *sdp)
{
	pr_info("withdraw\n");
}
