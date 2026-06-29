/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * gfs2_compat.h — minimal GFS2 type definitions for out-of-tree build.
 *
 * GFS2's internal headers are not exported.  This header provides the
 * subset of types, constants, and function declarations needed by
 * lock_etcd.  Must stay in sync with the target kernel's
 * fs/gfs2/lm_interface.h.
 */

#ifndef _GFS2_COMPAT_H
#define _GFS2_COMPAT_H

#include <linux/types.h>
#include <linux/parser.h>

#define GFS2_LOCKNAME_LEN 64

/* Lock states — from lm_interface.h */
#define LM_ST_UNLOCKED   0
#define LM_ST_EXCLUSIVE  1
#define LM_ST_DEFERRED   2
#define LM_ST_SHARED     3

/* Lock flags */
#define LM_FLAG_TRY      0x0001
#define LM_FLAG_TRY_1CB  0x0002
#define LM_FLAG_NOEXP    0x0004
#define LM_FLAG_ANY      0x0008

/* Lock request outcomes */
#define LM_OUT_CANCELED   2
#define LM_OUT_TRY_AGAIN  3
#define LM_OUT_DEADLOCK   4
#define LM_OUT_ERROR      5

/* Recovery results */
#define LM_RD_SUCCESS  0
#define LM_RD_GAVEUP   1

/* Forward declarations — opaque pointers for out-of-tree code */
struct gfs2_glock;
struct gfs2_sbd;

/* lm_lockops — the interface we implement */
struct lm_lockops {
	const char        *lm_proto_name;
	int  (*lm_mount)(struct gfs2_sbd *sdp, const char *table);
	void (*lm_first_done)(struct gfs2_sbd *sdp);
	void (*lm_recovery_result)(struct gfs2_sbd *sdp,
				   unsigned int jid, unsigned int result);
	void (*lm_unmount)(struct gfs2_sbd *sdp, bool clean);
	void (*lm_put_lock)(struct gfs2_glock *gl);
	void (*lm_lock)(struct gfs2_glock *gl,
			unsigned int req_state, unsigned int flags);
	void (*lm_cancel)(struct gfs2_glock *gl);
	const match_table_t *lm_tokens;
};

/* SDF_ flags — subset we use */
#define SDF_NOJOURNALID     6

/* GLF_ flags — subset we use */
#define GLF_BLOCKING        15

/* GFS2-exported functions (EXPORT_SYMBOL_GPL) */
int  gfs2_register_lockproto(const struct lm_lockops *ops);
void gfs2_unregister_lockproto(const struct lm_lockops *ops);
void gfs2_glock_complete(struct gfs2_glock *gl, int ret);
void gfs2_glock_cb(struct gfs2_glock *gl, unsigned int state);
void gfs2_glock_free(struct gfs2_glock *gl);

/* Bit manipulation helpers (normally from GFS2 util.h) */
#ifndef test_and_clear_bit_le
/* We only need basic bit ops — use the generic kernel ones */
#endif

#endif /* _GFS2_COMPAT_H */
