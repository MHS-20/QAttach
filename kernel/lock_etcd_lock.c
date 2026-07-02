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

	spin_lock_irqsave(&letcd_ordered_lock, flags);
	while (!list_is_first(&e->list, &letcd_ordered_list) && !e->completed) {
		spin_unlock_irqrestore(&letcd_ordered_lock, flags);
		wait_for_completion(&e->done);
		spin_lock_irqsave(&letcd_ordered_lock, flags);
	}
	spin_unlock_irqrestore(&letcd_ordered_lock, flags);
}

/* Mark this entry complete and wake the next waiter. */
void letcd_ordered_complete(struct letcd_ordered_entry *e)
{
	struct letcd_ordered_entry *next;
	unsigned long flags;

	spin_lock_irqsave(&letcd_ordered_lock, flags);
	e->completed = true;
	if (!list_empty(&e->list)) {
		list_del_init(&e->list);
		next = list_first_entry_or_null(&letcd_ordered_list,
						struct letcd_ordered_entry, list);
		if (next)
			complete(&next->done);
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

	gl->gl_req = req_state;

	if (req_state == LM_ST_UNLOCKED) {
		struct letcd_lock_rel rel = {
			.glock_number = gl->gl_name.ln_number,
			.glock_type   = gl->gl_name.ln_type,
		};
		/* Auto-yield on release: suppress immediate reacquire so
		 * a waiting node has time to grab the lock.  The agent
		 * clears the flag via LOCK_YIELD_CLEAR after the waiter
		 * finishes. */
		letcd_yield_set(gl->gl_name.ln_type, gl->gl_name.ln_number);
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

	/* Yield check: if this lock was yielded, suppress the request.
	 * letcd_yield_clear is called by the agent via netlink dispatch
	 * when the waiter finishes I/O. */
	if (letcd_yield_test(req.glock_type, req.glock_number)) {
		letcd_yield_clear(req.glock_type, req.glock_number);
		gfs2_glock_complete(gl, 0);
		return 0;
	}

	letcd_bast_insert(req.glock_type, req.glock_number, gl);
	letcd_pending_insert(req.request_id, gl,
			     req.glock_type, req.glock_number);

	if (!(flags & (LM_FLAG_TRY | LM_FLAG_TRY_1CB)))
		set_bit(GLF_BLOCKING, &gl->gl_flags);

	/* Ordered drain: wait for all earlier lock requests to complete.
	 * pending_insert enqueues into the sorted list; drain blocks until
	 * this request is at the head.  Both nodes sort independently by
	 * (type, number), producing the same global acquisition order.
	 */
	pe = letcd_pending_lookup(req.request_id);
	if (pe) {
		letcd_ordered_drain(&pe->ordered);
	}

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
