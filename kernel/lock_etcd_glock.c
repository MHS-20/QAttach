/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * lock_etcd_glock.c — hash tables for pending requests, BAST lookup,
 * and per-glock fencing revision storage.
 */

#define pr_fmt(fmt) "lock_etcd: " fmt

#include <linux/slab.h>
#include <linux/jhash.h>

#include "lock_etcd_internal.h"

/* ---- pending requests (request_id → glock *) ---- */

spinlock_t letcd_pending_lock;
EXPORT_SYMBOL(letcd_pending_lock);

DEFINE_HASHTABLE(letcd_pending_table, LETCD_PENDING_BITS);
EXPORT_SYMBOL(letcd_pending_table);

atomic64_t letcd_req_counter;
EXPORT_SYMBOL(letcd_req_counter);

void letcd_pending_insert(u64 request_id, struct gfs2_glock *gl)
{
	struct letcd_pending_entry *e;

	e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e) {
		pr_err("OOM pending entry %llu\n", request_id);
		return;
	}
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
			kfree(e);
			break;
		}
	}
	spin_unlock_bh(&letcd_pending_lock);

	return gl;
}
EXPORT_SYMBOL(letcd_pending_remove);

/* ---- BAST lookup (type, number → glock *) ---- */

#define LETCD_BAST_BITS 8

struct bast_entry {
	u32                type;
	u64                number;
	struct gfs2_glock  *gl;
	struct hlist_node  node;
};

static DEFINE_HASHTABLE(bast_table, LETCD_BAST_BITS);
static DEFINE_SPINLOCK(bast_lock);

void letcd_bast_insert(u32 glock_type, u64 glock_number,
		       struct gfs2_glock *gl)
{
	struct bast_entry *e;
	u32 key = jhash_2words(glock_type, (u32)glock_number, 0);

	e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (!e)
		return;

	e->type   = glock_type;
	e->number = glock_number;
	e->gl     = gl;

	spin_lock_bh(&bast_lock);
	hash_add(bast_table, &e->node, key);
	spin_unlock_bh(&bast_lock);
}
EXPORT_SYMBOL(letcd_bast_insert);

void letcd_bast_remove(u32 glock_type, u64 glock_number)
{
	struct bast_entry *e;
	u32 key = jhash_2words(glock_type, (u32)glock_number, 0);

	spin_lock_bh(&bast_lock);
	hash_for_each_possible(bast_table, e, node, key) {
		if (e->type == glock_type && e->number == glock_number) {
			hash_del(&e->node);
			kfree(e);
			break;
		}
	}
	spin_unlock_bh(&bast_lock);
}
EXPORT_SYMBOL(letcd_bast_remove);

struct gfs2_glock *letcd_bast_lookup(u32 glock_type, u64 glock_number)
{
	struct bast_entry *e;
	struct gfs2_glock *gl = NULL;
	u32 key = jhash_2words(glock_type, (u32)glock_number, 0);

	spin_lock_bh(&bast_lock);
	hash_for_each_possible(bast_table, e, node, key) {
		if (e->type == glock_type && e->number == glock_number) {
			gl = e->gl;
			break;
		}
	}
	spin_unlock_bh(&bast_lock);

	return gl;
}
EXPORT_SYMBOL(letcd_bast_lookup);

/* ---- per-glock revision tracking (fencing token) ---- */

#define LETCD_REV_BITS 8

struct rev_entry {
	struct gfs2_glock  *gl;
	s64                revision;
	struct hlist_node  node;
};

static DEFINE_HASHTABLE(rev_table, LETCD_REV_BITS);
static DEFINE_SPINLOCK(rev_lock);

void letcd_revision_set(struct gfs2_glock *gl, s64 revision)
{
	struct rev_entry *e;
	unsigned long key = (unsigned long)gl;
	bool found = false;

	spin_lock_bh(&rev_lock);
	hash_for_each_possible(rev_table, e, node, key) {
		if (e->gl == gl) {
			e->revision = revision;
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
		e->revision = revision;
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
