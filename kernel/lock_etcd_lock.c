/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include "lock_etcd_internal.h"

/* ---- ordered lock queue (deadlock prevention) ---- */

static LIST_HEAD(letcd_ordered_list);
static DEFINE_SPINLOCK(letcd_ordered_lock);

static u64 letcd_order_key(u32 type, u64 number)
{
	return ((u64)type << 56) | (number & 0x00FFFFFFFFFFFFFFULL);
}

/* Insert sorted by order_key (ascending).  Used before sending a lock
 * request so we can later drain all earlier entries.
 */
void letcd_ordered_enqueue(struct letcd_ordered_entry *e,
			   u32 glock_type, u64 glock_number)
{
	struct letcd_ordered_entry *cur;
	unsigned long flags;

	e->order_key = letcd_order_key(glock_type, glock_number);
	init_completion(&e->done);
	e->completed = false;

	spin_lock_irqsave(&letcd_ordered_lock, flags);
	list_for_each_entry(cur, &letcd_ordered_list, list) {
		if (e->order_key < cur->order_key) {
			list_add_tail(&e->list, &cur->list);
			spin_unlock_irqrestore(&letcd_ordered_lock, flags);
			return;
		}
	}
	list_add_tail(&e->list, &letcd_ordered_list);
	spin_unlock_irqrestore(&letcd_ordered_lock, flags);
}

/* Block until this entry is at the head of the ordered queue
 * (all earlier lock requests have completed).
 */
void letcd_ordered_drain(struct letcd_ordered_entry *e)
{
	unsigned long flags;
	struct letcd_ordered_entry *head;
	int loops = 0;

	spin_lock_irqsave(&letcd_ordered_lock, flags);
	while (!list_is_first(&e->list, &letcd_ordered_list) && !e->completed) {
		head = list_first_entry_or_null(&letcd_ordered_list,
						struct letcd_ordered_entry, list);
		if (head && loops == 0)
			pr_info("  DRAIN-BLOCKED: waiting behind ord=%#018llx (completed=%d)\n",
				head->order_key, head->completed);
		loops++;
		spin_unlock_irqrestore(&letcd_ordered_lock, flags);
		wait_for_completion(&e->done);
		spin_lock_irqsave(&letcd_ordered_lock, flags);
	}
	if (loops > 0)
		pr_info("  DRAIN-UNBLOCKED after %d waits, completed=%d\n",
			loops, e->completed);
	spin_unlock_irqrestore(&letcd_ordered_lock, flags);
}

/* Mark this entry complete and wake the next waiter. */
void letcd_ordered_complete(struct letcd_ordered_entry *e)
{
	struct letcd_ordered_entry *next;
	unsigned long flags;

	pr_info("  ORD-COMPLETE ord=%#018llx\n", e->order_key);

	spin_lock_irqsave(&letcd_ordered_lock, flags);
	e->completed = true;
	if (!list_empty(&e->list)) {
		list_del_init(&e->list);
		next = list_first_entry_or_null(&letcd_ordered_list,
						struct letcd_ordered_entry, list);
		if (next) {
			pr_info("  ORD-NEXT ord=%#018llx\n", next->order_key);
			complete(&next->done);
		}
	} else {
		/* Enqueue hasn't run yet — wake the enqueuer by completing now. */
		complete(&e->done);
	}
	spin_unlock_irqrestore(&letcd_ordered_lock, flags);
}

/* ---- lock operations ---- */

int letcd_lock(struct gfs2_glock *gl, unsigned int req_state,
	       unsigned int flags)
{
	struct letcd_lock_req req;
	struct letcd_pending_entry *pe;
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
		letcd_bast_remove(gl->gl_name.ln_type, gl->gl_name.ln_number);
		gfs2_glock_complete(gl, req_state);
		return 0;
	}

	req.request_id     = atomic64_inc_return(&letcd_req_counter);
	req.glock_number   = gl->gl_name.ln_number;
	req.glock_type     = gl->gl_name.ln_type;
	req.requested_mode = req_state;
	req.node_epoch     = letcd_mount_ctx.mount_epoch;

	pr_info("  ACQUIRE t=%u n=%llu mode=%u reqid=%lld\n",
		req.glock_type, req.glock_number,
		req.requested_mode, req.request_id);

	/* Yield check: if this lock was yielded (by agent BAST watch),
	 * suppress reacquire.  The flag persists until the agent sends
	 * YIELD_CLEAR after the waiter finishes I/O. */
	if (letcd_yield_test(req.glock_type, req.glock_number)) {
		pr_info("  YIELD-SUPPRESS t=%u n=%llu\n",
			req.glock_type, req.glock_number);
		gfs2_glock_complete(gl, 0);
		return 0;
	}

	letcd_bast_insert(req.glock_type, req.glock_number, gl);
	letcd_pending_insert(req.request_id, gl,
			     req.glock_type, req.glock_number);

	pr_info("  INSERTED t=%u n=%llu reqid=%lld ord=%#018llx\n",
		req.glock_type, req.glock_number, req.request_id,
		letcd_order_key(req.glock_type, req.glock_number));

	if (!(flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB)))
		set_bit(GLF_BLOCKING, &gl->gl_flags);

	/* Ordered drain: wait for all earlier lock requests to complete.
	 * pending_insert enqueues into the sorted list; drain blocks until
	 * this request is at the head.  Both nodes sort independently by
	 * (type, number), producing the same global acquisition order.
	 */
	pe = letcd_pending_lookup(req.request_id);
	if (pe) {
		pr_info("  DRAIN-WAIT t=%u n=%llu reqid=%lld\n",
			req.glock_type, req.glock_number, req.request_id);
		letcd_ordered_drain(&pe->ordered);
		pr_info("  DRAIN-DONE t=%u n=%llu reqid=%lld\n",
			req.glock_type, req.glock_number, req.request_id);
	}

	ret = letcd_nl_send_msg(LETCD_MSG_LOCK_REQ, &req, sizeof(req));
	pr_info("  NL-SENT t=%u n=%llu reqid=%lld ret=%d\n",
		req.glock_type, req.glock_number, req.request_id, ret);
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
