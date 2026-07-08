# QAttach — System Overview & Current Status

## What It Is

QAttach replaces the standard DLM stack (Corosync + Pacemaker + `lock_dlm`)
that GFS2 normally needs with an etcd-backed lock manager. Three EC2 compute
nodes share an EBS io2 Multi-Attach volume. Instead of DLM daemons coordinating
lock state, a custom kernel module (`lock_etcd`, built into `gfs2.ko`) speaks
Netlink to a Go daemon (`cluster-agent`) on each node, and that daemon uses
etcd (3-node Raft cluster, one per compute node) as the source of truth for
who holds which lock.

A GFS2 filesystem sits on top. When GFS2 needs a lock (glock), its work
function calls `lm_lock` which is our `letcd_lock()`. That function sends a
Netlink message to the agent. The agent does a CAS transaction in etcd to
claim the lock, then replies GRANT, DENY, or WAIT.

## What Works

Everything in the single-node path. Format the volume, mount GFS2 on 3 nodes,
read/write/create files on any single node, journal assignment, etcd cluster
formation, fencing infrastructure — all stable. The deployment pipeline
(create instances, build + deploy custom kernel, setup daemons, mount) is
fully scripted.

## What Doesn't Work — The Core Problem

**Anything that requires two nodes to touch the same file or directory at
the same time hangs.** Specifically: concurrent writes from two nodes to the
same file, and metadata operations (chmod, chown) from a node that didn't
do the mount.

The hang is **not in our code**. We have verified this with kernel debug
probes:

1. Processes block in `gfs2_glock_wait` — GFS2's own function that waits for
   a glock to be granted.
2. The kernel's glock work function (`do_xmote`) **never calls our
   `letcd_lock()`** for the hung glock.
3. The agent is alive and responsive — it processes periodic quotad locks
   every 30s without issue.
4. No BAST (cross-node notification) events ever fire, because the waiter's
   lock request never reaches etcd in the first place.

The problem sits inside GFS2's glock state machine: a glock gets stuck in
`GLF_DEMOTE` state with a holder present. When `do_xmote` sees both
conditions (demote flag set AND a holder exists), it returns immediately
without calling the lock manager. The glock is frozen.

## Why This Doesn't Happen With DLM

DLM has a fundamental architectural advantage: it's a **central arbiter**
that sees both the lock dependency graph and the queue of pending requests.
When Node B wants a lock held by Node A, DLM knows about B's request before
it even sends a BAST to A. It can guarantee B gets priority after A releases.

Our etcd approach is flat: each node's agent only sees etcd keys (who
currently holds the lock). A waiter writes a BAST key to signal "someone
wants this lock," but by the time the holder processes it, GFS2 may have
already started a new glock cycle that bypasses the lock manager entirely.

## What We Tried Before Identifying the Root Cause

The debug docs (`docs/debug/deadlock_issuelog.md`) document 10 different
approaches attempted over the development history, spanning weeks:

| Approach | What went wrong |
|---|---|
| BAST + atomic handoff | Livelock — holder reacquires faster than waiter can claim |
| No BAST, just wait | Holder-reacquire race — holder wins every time |
| Kernel ordered queue | Only orders within a node, not between nodes |
| Global lock ordering + DENY | Kernel panic — GFS2 treats ESTALE as fatal filesystem error |
| Global lock ordering + WAIT | No effect — doesn't prevent the race |
| Type-specific ordering | Wrong diagnosis — contention is single-lock, not cross-type |
| HasWaiter check + yield | TOCTOU races, self-yield, watch event handling bugs |
| Proactive BAST watch + persistent yield | Works for agent-mediated locks, but the hang we see is *before* the lock manager |

The key insight from this history: we spent a long time perfecting the
agent-side handoff mechanism, but the actual hang occurs above our layer,
inside GFS2's own glock state machine before `lm_lock` is ever called.

## Current State Summary

| Capability | Status |
|---|---|
| Custom kernel build pipeline (launch.sh) | Stable |
| Infrastructure provisioning (create/destroy) | Stable |
| Agent build + deployment (setup-compute.sh) | Stable (first run only; cert regeneration breaks on re-run) |
| etcd colocation on compute nodes | Stable (3-node cluster forms correctly on first deploy) |
| GFS2 format + mount on all nodes | Stable |
| Single-node I/O (read, write, create, append) | Stable |
| Agent processes lock requests | Stable (30s quotad cycle confirmed) |
| Cross-node concurrent I/O | **Blocked** — hangs in GFS2 glock state machine |
| Metadata operations from non-holder | **Blocked** — same root cause |
| Fencing via EC2 API | Implemented but unusable without IAM role on compute nodes |

## Next Steps

The priority is understanding why GFS2's glock state machine stalls. This
requires deeper analysis of GFS2's glock work function, specifically:

1. What makes `gl_demote_state` be set and never cleared?
2. Why does `find_first_holder()` return true, preventing `do_xmote` from
   calling `lm_lock`?
3. Is the glock's `gl_target` diverging from `gl_state` in a way that
   stalls the state machine?

This work happens inside the GFS2 source tree (`fs/gfs2/glock.c`), not in
our lock_etcd code.
