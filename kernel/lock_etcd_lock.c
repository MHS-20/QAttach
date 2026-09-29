/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include "lock_etcd_internal.h"

/* ---- lock operations ---- */

/* Publish the value block when giving up EX, as DLM does for an unlock or
 * down-conversion with DLM_LKF_VALBLK.  Only an EX holder may write it. */
static u32 letcd_lvb_out(struct gfs2_glock *gl, u8 *lvb)
{
	BUILD_BUG_ON(LETCD_LVB_SIZE != GDLM_LVB_SIZE);
	BUILD_BUG_ON(LETCD_FLAG_TRY != LM_FLAG_TRY ||
		     LETCD_FLAG_TRY_1CB != LM_FLAG_TRY_1CB ||
		     LETCD_FLAG_NOEXP != LM_FLAG_NOEXP);
	if (!gl->gl_lksb.sb_lvbptr || gl->gl_state != LM_ST_EXCLUSIVE)
		return 0;
	memcpy(lvb, gl->gl_lksb.sb_lvbptr, LETCD_LVB_SIZE);
	return 1;
}

static void letcd_send_rel(struct gfs2_glock *gl)
{
	struct letcd_lock_rel rel = {
		.glock_number = gl->gl_name.ln_number,
		.glock_type   = gl->gl_name.ln_type,
	};

	rel.lvb_valid = letcd_lvb_out(gl, rel.lvb);
	letcd_nl_send_msg(LETCD_MSG_LOCK_REL, &rel, sizeof(rel));
}

int letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
	       unsigned int flags)
{
	struct letcd_lock_req req = {};
	int ret;

	gl->gl_req = req_state;

	pr_info("==> t=%u n=%llu st=%u fl=%u glst=%u gltgt=%u tr=%u\n",
		gl->gl_name.ln_type, gl->gl_name.ln_number,
		req_state, flags, gl->gl_state, gl->gl_target,
		test_bit(GLF_BLOCKING, &gl->gl_flags) ? 1 : 0);

	if (req_state == LM_ST_UNLOCKED) {
		pr_info("  UNLOCK t=%u n=%llu\n",
			gl->gl_name.ln_type, gl->gl_name.ln_number);
		letcd_send_rel(gl);
		/* Keep revision — cleared only on glock free.
		 * dispatch_lock_grant uses it to detect handoff. */
		gfs2_glock_complete(gl, req_state);
		return 0;
	}

	req.request_id     = atomic64_inc_return(&letcd_req_counter);
	req.glock_number   = gl->gl_name.ln_number;
	req.glock_type     = gl->gl_name.ln_type;
	req.requested_mode = req_state;
	req.lvb_valid      = letcd_lvb_out(gl, req.lvb);
	/* NOEXP marks the requests recovery itself makes; the agent grants
	 * them while a recovery barrier holds every other request back. */
	/* TRY is decided by the agent against etcd, as DLM_LKF_NOQUEUE is
	 * by DLM: failing it locally breaks flock -n and every remote
	 * delete poke (TRY_1CB), leaving unlinked inodes allocated. */
	req.flags          = flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB |
				  LM_FLAG_NOEXP);

	pr_info("  ACQUIRE t=%u n=%llu mode=%u reqid=%lld\n",
		req.glock_type, req.glock_number,
		req.requested_mode, req.request_id);

	letcd_bast_insert(req.glock_type, req.glock_number, gl);
	letcd_pending_insert(req.request_id, gl);

	pr_info("  INSERTED t=%u n=%llu reqid=%lld\n",
		req.glock_type, req.glock_number, req.request_id);

	if (!req.flags)
		set_bit(GLF_BLOCKING, &gl->gl_flags);

	ret = letcd_nl_send_msg(LETCD_MSG_LOCK_REQ, &req, sizeof(req));
	pr_info("  NL-SENT t=%u n=%llu reqid=%lld ret=%d\n",
		req.glock_type, req.glock_number, req.request_id, ret);

	if (ret < 0) {
		pr_warn("  NL-FAIL t=%u n=%llu reqid=%lld ret=%d — cleaning up\n",
			req.glock_type, req.glock_number, req.request_id, ret);
		letcd_pending_remove(req.request_id);
		letcd_bast_remove(req.glock_type, req.glock_number);
		/* do_xmote() only tolerates -ENODEV from lm_lock; any other
		 * error hits GLOCK_BUG_ON(gl, !gfs2_withdrawn(sdp)) and
		 * panics.  A dead agent must degrade to I/O errors instead. */
		return -ENODEV;
	}

	return 0;
}

void letcd_put_lock(struct gfs2_glock *gl)
{
	letcd_send_rel(gl);
	letcd_bast_remove(gl->gl_name.ln_type, gl->gl_name.ln_number);
	gfs2_glock_free(gl);
}

/* GFS2 cancels a request it has stopped waiting for — an iopen upgrade
 * after its 5s evict timeout — and then sleeps until the request completes.
 * The agent answers with a DENY carrying LETCD_DENY_CANCELED, or with the
 * GRANT if it won the race; either completes the request.  The glock stays
 * live, so its BAST entry must survive. */
void letcd_cancel(struct gfs2_glock *gl)
{
	struct letcd_lock_cancel c = {
		.glock_number = gl->gl_name.ln_number,
		.glock_type   = gl->gl_name.ln_type,
	};

	letcd_nl_send_msg(LETCD_MSG_CANCEL, &c, sizeof(c));
}
