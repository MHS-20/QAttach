/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include "lock_etcd_internal.h"

/* ---- lock operations ---- */

int letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
	       unsigned int flags)
{
	struct letcd_lock_req req;
	int ret;

	gl->gl_req = req_state;

	pr_info("==> t=%u n=%llu st=%u fl=%u glst=%u gltgt=%u tr=%u\n",
		gl->gl_name.ln_type, gl->gl_name.ln_number,
		req_state, flags, gl->gl_state, gl->gl_target,
		test_bit(GLF_BLOCKING, &gl->gl_flags) ? 1 : 0);

	if (req_state == LM_ST_UNLOCKED) {
		struct letcd_lock_rel rel = {
			.glock_number = gl->gl_name.ln_number,
			.glock_type   = gl->gl_name.ln_type,
		};
		pr_info("  UNLOCK t=%u n=%llu\n",
			gl->gl_name.ln_type, gl->gl_name.ln_number);
		letcd_nl_send_msg(LETCD_MSG_LOCK_REL, &rel, sizeof(rel));
		letcd_revision_clear(gl);
		gfs2_glock_complete(gl, req_state);
		return 0;
	}

	/* TRY/TRY_1CB: caller does not want to block.  Complete
	 * synchronously with LM_OUT_TRY_AGAIN (0x20) — GFS2's
	 * finish_xmote treats this as a non-fatal "try again" error
	 * and skips the lock without aborting the mount.  Used for
	 * mount-time journal recovery checks on other nodes' journals. */
	if (flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB)) {
		pr_info("  TRY-DENY t=%u n=%llu mode=%u fl=0x%x\n",
			gl->gl_name.ln_type, gl->gl_name.ln_number,
			req_state, flags);
		gfs2_glock_complete(gl, LM_OUT_TRY_AGAIN);
		return 0;
	}

	req.request_id     = atomic64_inc_return(&letcd_req_counter);
	req.glock_number   = gl->gl_name.ln_number;
	req.glock_type     = gl->gl_name.ln_type;
	req.requested_mode = req_state;

	pr_info("  ACQUIRE t=%u n=%llu mode=%u reqid=%lld\n",
		req.glock_type, req.glock_number,
		req.requested_mode, req.request_id);

	letcd_bast_insert(req.glock_type, req.glock_number, gl);
	letcd_pending_insert(req.request_id, gl,
			     req.glock_type, req.glock_number);

	pr_info("  INSERTED t=%u n=%llu reqid=%lld\n",
		req.glock_type, req.glock_number, req.request_id);

	if (!(flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB)))
		set_bit(GLF_BLOCKING, &gl->gl_flags);

	ret = letcd_nl_send_msg(LETCD_MSG_LOCK_REQ, &req, sizeof(req));
	pr_info("  NL-SENT t=%u n=%llu reqid=%lld ret=%d\n",
		req.glock_type, req.glock_number, req.request_id, ret);

	if (ret < 0) {
		pr_warn("  NL-FAIL t=%u n=%llu reqid=%lld ret=%d — cleaning up\n",
			req.glock_type, req.glock_number, req.request_id, ret);
		letcd_pending_remove(req.request_id);
		letcd_bast_remove(req.glock_type, req.glock_number);
		return ret;
	}

	return 0;
}

void letcd_put_lock(struct gfs2_glock *gl)
{
	struct letcd_lock_rel rel = {
		.glock_number = gl->gl_name.ln_number,
		.glock_type   = gl->gl_name.ln_type,
	};
	letcd_nl_send_msg(LETCD_MSG_LOCK_REL, &rel, sizeof(rel));
	letcd_revision_clear(gl);
	letcd_bast_remove(gl->gl_name.ln_type, gl->gl_name.ln_number);
	gfs2_glock_free(gl);
}

void letcd_cancel(struct gfs2_glock *gl)
{
	letcd_bast_remove(gl->gl_name.ln_type, gl->gl_name.ln_number);
}
