/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include <linux/slab.h>
#include <linux/jhash.h>
#include "lock_etcd_internal.h"

/* ---- pending requests ---- */

spinlock_t letcd_pending_lock;
EXPORT_SYMBOL(letcd_pending_lock);
DEFINE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
EXPORT_SYMBOL(letcd_pending_table);
atomic64_t letcd_req_counter;
EXPORT_SYMBOL(letcd_req_counter);

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl,
			  u32 glock_type, u64 glock_number)
{
	struct letcd_pending_entry *e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e)
		return;
	e->request_id = request_id;
	e->gl = gl;
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

void letcd_bast_insert(u32 t, u64 n, struct gfs2_glock *gl)
{
	struct bast_entry *e = kmalloc(sizeof(*e), GFP_ATOMIC);
	u32 key;
	if (!e)
		return;
	e->type = t;
	e->number = n;
	e->gl = gl;
	key = jhash_2words(t, (u32)n, 0);
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

/* ---- yield infrastructure ---- */

#define LETCD_YIELD_BITS 8
struct yield_entry {
	u32 glock_type;
	u64 glock_number;
	struct hlist_node node;
};
static DEFINE_HASHTABLE(yield_table, LETCD_YIELD_BITS);
static DEFINE_SPINLOCK(yield_lock);

static u32 yield_hash(u32 type, u64 number)
{
	return jhash_2words(type, (u32)(number & 0xFFFFFFFF), 0);
}

void letcd_yield_set(u32 glock_type, u64 glock_number)
{
	struct yield_entry *e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e)
		return;
	e->glock_type = glock_type;
	e->glock_number = glock_number;
	spin_lock_bh(&yield_lock);
	hash_add(yield_table, &e->node, yield_hash(glock_type, glock_number));
	spin_unlock_bh(&yield_lock);
}

bool letcd_yield_test(u32 glock_type, u64 glock_number)
{
	struct yield_entry *e;
	u32 key = yield_hash(glock_type, glock_number);
	spin_lock_bh(&yield_lock);
	hash_for_each_possible(yield_table, e, node, key) {
		if (e->glock_type == glock_type &&
		    e->glock_number == glock_number) {
			spin_unlock_bh(&yield_lock);
			return true;
		}
	}
	spin_unlock_bh(&yield_lock);
	return false;
}

void letcd_yield_clear(u32 glock_type, u64 glock_number)
{
	struct yield_entry *e;
	u32 key = yield_hash(glock_type, glock_number);
	spin_lock_bh(&yield_lock);
	hash_for_each_possible(yield_table, e, node, key) {
		if (e->glock_type == glock_type &&
		    e->glock_number == glock_number) {
			hash_del(&e->node);
			kfree(e);
			break;
		}
	}
	spin_unlock_bh(&yield_lock);
}

void letcd_yield_cleanup(void)
{
	struct yield_entry *e;
	struct hlist_node *tmp;
	int bkt;
	spin_lock_bh(&yield_lock);
	hash_for_each_safe(yield_table, bkt, tmp, e, node) {
		hash_del(&e->node);
		kfree(e);
	}
	spin_unlock_bh(&yield_lock);
}
EXPORT_SYMBOL(letcd_yield_set);
EXPORT_SYMBOL(letcd_yield_test);
EXPORT_SYMBOL(letcd_yield_clear);
EXPORT_SYMBOL(letcd_yield_cleanup);
