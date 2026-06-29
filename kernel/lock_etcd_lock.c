/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include "lock_etcd_internal.h"

int letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
	       unsigned int flags)
{
	struct letcd_lock_req req;

	gl->gl_req = req_state;

	if (req_state == LM_ST_UNLOCKED) {
		struct letcd_lock_rel rel = {
			.glock_number = gl->gl_name.ln_number,
			.glock_type   = gl->gl_name.ln_type,
		};
		letcd_nl_send_msg(LETCD_MSG_LOCK_REL, &rel, sizeof(rel));
		letcd_revision_clear(gl);
		letcd_bast_remove(gl->gl_name.ln_type, gl->gl_name.ln_number);
		gfs2_glock_complete(gl, req_state);
		return 0;
	}

	req.request_id    = atomic64_inc_return(&letcd_req_counter);
	req.glock_number  = gl->gl_name.ln_number;
	req.glock_type    = gl->gl_name.ln_type;
	req.requested_mode = req_state;

	letcd_bast_insert(req.glock_type, req.glock_number, gl);
	letcd_pending_insert(req.request_id, gl);

	if (!(flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB)))
		set_bit(GLF_BLOCKING, &gl->gl_flags);

	letcd_nl_send_msg(LETCD_MSG_LOCK_REQ, &req, sizeof(req));
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
