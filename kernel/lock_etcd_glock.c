/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include <linux/slab.h>
#include <linux/jhash.h>
#include <linux/timer.h>
#include "lock_etcd_internal.h"

/* ---- pending requests ---- */

spinlock_t letcd_pending_lock;
EXPORT_SYMBOL(letcd_pending_lock);
DEFINE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
EXPORT_SYMBOL(letcd_pending_table);
atomic64_t letcd_req_counter;
EXPORT_SYMBOL(letcd_req_counter);

static void letcd_pending_timeout_scan(struct timer_list *);
DEFINE_TIMER(letcd_wait_timeout_timer, letcd_pending_timeout_scan);

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl,
			  u32 glock_type, u64 glock_number)
{
	struct letcd_pending_entry *e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e)
		return;
	e->request_id = request_id;
	e->gl = gl;
	e->wait_start = 0;
	spin_lock_bh(&letcd_pending_lock);
	hash_add(letcd_pending_table, &e->node, request_id);
	spin_unlock_bh(&letcd_pending_lock);
}
EXPORT_SYMBOL(letcd_pending_insert);

struct gfs2_glock *letcd_pending_remove(u64 request_id)
{
	struct letcd_pending_entry *e;
	struct gfs2_glock *gl = NULL;

	spin_lock_bh(&letcd_pending_lock);
	hash_for_each_possible(letcd_pending_table, e, node, request_id) {
		if (e->request_id == request_id) {
			gl = e->gl;
			hash_del(&e->node);
			spin_unlock_bh(&letcd_pending_lock);
			kfree(e);
			return gl;
		}
	}
	spin_unlock_bh(&letcd_pending_lock);
	return gl;
}
EXPORT_SYMBOL(letcd_pending_remove);

struct gfs2_glock *letcd_pending_find(u64 request_id)
{
	struct letcd_pending_entry *e;
	struct gfs2_glock *gl = NULL;

	spin_lock_bh(&letcd_pending_lock);
	hash_for_each_possible(letcd_pending_table, e, node, request_id) {
		if (e->request_id == request_id) {
			gl = e->gl;
			break;
		}
	}
	spin_unlock_bh(&letcd_pending_lock);
	return gl;
}
EXPORT_SYMBOL(letcd_pending_find);

void letcd_pending_mark_wait(u64 request_id)
{
	struct letcd_pending_entry *e;

	spin_lock_bh(&letcd_pending_lock);
	hash_for_each_possible(letcd_pending_table, e, node, request_id) {
		if (e->request_id == request_id) {
			e->wait_start = jiffies;
			break;
		}
	}
	spin_unlock_bh(&letcd_pending_lock);
}
EXPORT_SYMBOL(letcd_pending_mark_wait);

static void letcd_pending_timeout_scan(struct timer_list *timer)
{
	struct letcd_pending_entry *e;
	struct hlist_node *tmp;
	struct gfs2_glock *expired[16];
	int count = 0;
	unsigned long now = jiffies;
	int bkt;

	spin_lock_bh(&letcd_pending_lock);
	hash_for_each_safe(letcd_pending_table, bkt, tmp, e, node) {
		if (e->wait_start &&
		    time_after(now, e->wait_start + LETCD_WAIT_TIMEOUT)) {
			expired[count++] = e->gl;
			hash_del(&e->node);
			kfree(e);
			if (count >= 16)
				break;
		}
	}
	spin_unlock_bh(&letcd_pending_lock);

	while (count > 0) {
		count--;
		pr_info("  WAIT-TO t=%u n=%llu\n",
			expired[count]->gl_name.ln_type,
			expired[count]->gl_name.ln_number);
		/* LM_OUT_TRY_AGAIN is only legal when the holder set
		 * LM_FLAG_TRY/TRY_1CB.  For a plain request finish_xmote()
		 * falls through to GLOCK_BUG_ON() when gl_state is EX. */
		gfs2_glock_complete(expired[count], LM_OUT_ERROR);
	}

	mod_timer(&letcd_wait_timeout_timer, jiffies + HZ);
}

/* ---- BAST lookup ---- */

#define LETCD_BAST_BITS 8
struct bast_entry {
	u32 type;
	u64 number;
	struct gfs2_glock *gl;
	struct hlist_node node;
};
static DEFINE_HASHTABLE(bast_table, LETCD_BAST_BITS);
static DEFINE_SPINLOCK(bast_lock);

/* Entries live from the first ACQUIRE until letcd_put_lock() frees the
 * glock, so they survive UNLOCK→ACQUIRE cycles (a BAST may arrive for a
 * cached glock).  Re-inserting must therefore update in place, or the
 * table grows without bound under sustained I/O. */
void letcd_bast_insert(u32 t, u64 n, struct gfs2_glock *gl)
{
	struct bast_entry *e;
	u32 key = jhash_2words(t, (u32)n, 0);

	spin_lock_bh(&bast_lock);
	hash_for_each_possible(bast_table, e, node, key) {
		if (e->type == t && e->number == n) {
			e->gl = gl;
			spin_unlock_bh(&bast_lock);
			return;
		}
	}
	spin_unlock_bh(&bast_lock);

	e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e)
		return;
	e->type = t;
	e->number = n;
	e->gl = gl;
	spin_lock_bh(&bast_lock);
	hash_add(bast_table, &e->node, key);
	spin_unlock_bh(&bast_lock);
}
EXPORT_SYMBOL(letcd_bast_insert);

void letcd_bast_remove(u32 t, u64 n)
{
	struct bast_entry *e;
	u32 key = jhash_2words(t, (u32)n, 0);

	spin_lock_bh(&bast_lock);
	hash_for_each_possible(bast_table, e, node, key) {
		if (e->type == t && e->number == n) {
			hash_del(&e->node);
			kfree(e);
			break;
		}
	}
	spin_unlock_bh(&bast_lock);
}
EXPORT_SYMBOL(letcd_bast_remove);

struct gfs2_glock *letcd_bast_lookup(u32 t, u64 n)
{
	struct bast_entry *e;
	struct gfs2_glock *gl = NULL;
	u32 key = jhash_2words(t, (u32)n, 0);

	spin_lock_bh(&bast_lock);
	hash_for_each_possible(bast_table, e, node, key) {
		if (e->type == t && e->number == n) {
			gl = e->gl;
			break;
		}
	}
	spin_unlock_bh(&bast_lock);
	return gl;
}
EXPORT_SYMBOL(letcd_bast_lookup);

/* ---- revision tracking ---- */

#define LETCD_REV_BITS 8
struct rev_entry {
	struct gfs2_glock *gl;
	s64 revision;
	struct hlist_node node;
};
static DEFINE_HASHTABLE(rev_table, LETCD_REV_BITS);
static DEFINE_SPINLOCK(rev_lock);

void letcd_revision_set(struct gfs2_glock *gl, s64 rev)
{
	struct rev_entry *e;
	unsigned long key = (unsigned long)gl;
	bool found = false;

	spin_lock_bh(&rev_lock);
	hash_for_each_possible(rev_table, e, node, key) {
		if (e->gl == gl) {
			e->revision = rev;
			found = true;
			break;
		}
	}
	if (!found) {
		spin_unlock_bh(&rev_lock);
		e = kmalloc(sizeof(*e), GFP_ATOMIC);
		if (!e)
			return;
		e->gl = gl;
		e->revision = rev;
		spin_lock_bh(&rev_lock);
		hash_add(rev_table, &e->node, key);
	}
	spin_unlock_bh(&rev_lock);
}
EXPORT_SYMBOL(letcd_revision_set);

s64 letcd_revision_get(struct gfs2_glock *gl)
{
	struct rev_entry *e;
	unsigned long key = (unsigned long)gl;
	s64 rev = 0;

	spin_lock_bh(&rev_lock);
	hash_for_each_possible(rev_table, e, node, key) {
		if (e->gl == gl) {
			rev = e->revision;
			break;
		}
	}
	spin_unlock_bh(&rev_lock);
	return rev;
}
EXPORT_SYMBOL(letcd_revision_get);

void letcd_revision_clear(struct gfs2_glock *gl)
{
	struct rev_entry *e;
	unsigned long key = (unsigned long)gl;

	spin_lock_bh(&rev_lock);
	hash_for_each_possible(rev_table, e, node, key) {
		if (e->gl == gl) {
			hash_del(&e->node);
			kfree(e);
			break;
		}
	}
	spin_unlock_bh(&rev_lock);
}
EXPORT_SYMBOL(letcd_revision_clear);
