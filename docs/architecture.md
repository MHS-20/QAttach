# QAttach System Architecture

## Overview

QAttach replaces the DLM (Distributed Lock Manager) stack traditionally used with GFS2
(Corosync + Pacemaker + `lock_dlm`) with an etcd-backed locking protocol.  A custom
kernel module (`lock_etcd`) implements GFS2's `lm_lockops` interface and communicates
with a userspace Go daemon (`cluster-agent`) over AF_NETLINK.  The daemon uses etcd
as the single source of truth for lock state, membership, and fencing coordination.
etcd is colocated on each compute node; the agent handles bootstrap, join, and member
removal (`internal/membership/`).  No dedicated etcd instances or NLB are needed.

```
┌──────────────────────────────────────────────────────────────┐
│                     Compute Node 0                           │
│                                                              │
│  ┌───────────┐   Netlink   ┌──────────────┐  gRPC+mTLS      │
│  │ lock_etcd │◄───────────►│ cluster-agent│◄───────┐        │
│  │ (kernel)  │  family 31  │   (Go)       │        │        │
│  └────┬──────┘             └──────┬───────┘   ┌────┴──────┐ │
│       │ lm_lockops                │ EC2 API   │   etcd    │ │
│  ┌────┴──────┐                    │(fencing)  │ (local)   │ │
│  │   GFS2    │                    │           └────┬──────┘ │
│  └────┬──────┘                    │◄──peer─────────┼──────┐ │
│       │                           │                │      │ │
│  ┌────┴──────┐                    │                │      │ │
│  │ EBS io2   │                    │                │      │ │
│  │ MultiAttach│                   │                │      │ │
│  └───────────┘                    │                │      │ │
└───────────────────────────────────┼────────────────┼──────┼─┘
                                    │                │      │
                         ┌──────────┴─────┐  ┌───────┴──────┴─┐
                         │ Compute Node 1 │  │ Compute Node 2 │
                         │ (identical)    │  │ (identical)    │
                         └────────────────┘  └────────────────┘
                                    │                │
                                    └────────┬───────┘
                                    EBS io2 Multi-Attach
```

## Components

### lock_etcd (kernel module)

A Linux kernel module implementing the `lm_lockops` interface that GFS2 uses to
interact with a lock manager.  Compiled as part of the GFS2 kernel module (in-tree,
not a separate `.ko`).  Replaces `lock_dlm`.

Responsibilities:

- Register a custom AF_NETLINK family (31) for communication with the agent
- Translate GFS2 glock requests into netlink messages
- Track the agent's PID for unicast replies
- Maintain a pending-request table (maps request IDs to glocks awaiting completion)
- Maintain a BAST lookup table (maps glock identity to glocks that may receive callbacks)
- Store fencing tokens (etcd revisions) in glock private data
- Validate fencing tokens on every lock re-grant to detect stale cache

### cluster-agent (Go daemon)

One per compute node. The bridge between the kernel and etcd.

Responsibilities:

- Maintain an etcd session lease (TTL 15s, keepalive every 5s)
- Register the node in etcd under the session lease
- Receive netlink messages from the kernel (mount, lock, unlock, unmount)
- Translate lock requests into etcd CAS transactions
- Watch for BAST requests on held locks and relay them to the kernel
- Handle lock contention by writing BAST request keys and watching for release
- Assign journal IDs via etcd CAS at mount time
- Monitor member keys for session expiry (fencing detection)
- Execute fencing via EC2 API (StopInstances / DetachVolume) when winning a CAS race
- Handle ASG lifecycle hooks for graceful termination

### etcd (3-node Raft cluster)

Source of truth for all distributed state. No node-to-node monitoring.

Key categories:

- Membership: which nodes are alive (session lease)
- Fencing: CAS race keys for failed nodes
- Locks: glock ownership and mode
- Journals: slot assignment
- BAST requests: signals from waiters to holders

## Data Flow

### Mount

```
GFS2 mount(2)
  → gfs2_fill_super
    → lm_mount() [lock_etcd_mount.c]
      → letcd_nl_send_msg(LETCD_MSG_MOUNT_REQ, ...)
        → agent receives, assigns JID via etcd CAS
        → agent sends MOUNT_RESP with jid
      → kernel waits on completion (60s timeout)
      → sets ls_jid, continues mount
```

### Lock Acquire

```
GFS2 needs glock
  → letcd_lock(gl, mode)
    → yield check: if yielded AND gl_state == LM_ST_UNLOCKED →
      suppress reacquire, complete(gl, 0), return
      (conversions EX→SH pass through normally)
    → letcd_nl_send_msg(LETCD_MSG_LOCK_REQ, ...)
    → returns 0 (async — completion callback later)
    → [agent processes: etcd CAS → grant/deny/wait]
    → [agent sends: LOCK_GRANT / LOCK_DENY / LOCK_WAIT]
    → [kernel dispatch completes glock]
```

### Lock Release

```
GFS2 releases glock
  → letcd_lock(gl, LM_ST_UNLOCKED)
    → letcd_nl_send_msg(LETCD_MSG_LOCK_REL, ...)
    → gfs2_glock_complete(gl, 0)
    → [agent removes entry from etcd holder array]
```

### BAST (Blocking AST)

```
Node B agent: lock CAS fails → lock contended
  → writes /locks/bast/{type}/{number} with target mode
  → sends LOCK_WAIT to kernel
  → watches lock key for release

Node A agent: bast watch fires on /locks/bast/... (watchBastAndYield goroutine)
  → sends BAST(UNLOCK) to kernel → gfs2_glock_cb demotes lock
  → sends LOCK_YIELD to kernel → sets yield flag (persists until YIELD_CLEAR)
  → waits for ctx.Done() — kernel processes BAST and release/convert
  → ctx cancelled by releaseHeldLock (from self-contention handler or HandleLockRelease)
  → watches lock key for handoff completion (delete = waiter done)
  → on completion: sends YIELD_CLEAR to kernel
```

The yield flag is conditional — conversions (EX→SH, SH→UN) pass through normally.
Reacquisitions (gl_state == LM_ST_UNLOCKED) are suppressed until the agent sends
YIELD_CLEAR after the waiter finishes I/O.

### Epoch Validation

```
Mount:
  kernel → MOUNT_REQ → agent
  agent reads cluster/epoch → returns epoch in MOUNT_RESP
  kernel stores epoch

Lock Acquire:
  kernel sends LOCK_REQ with node_epoch
  agent compares node_epoch vs cached cluster_epoch
  if cluster_epoch > node_epoch: deny (DenyReasonStaleEpoch)
  → kernel returns -ESTALE to GFS2 → node withdraws
```

The epoch is a monotonically-increasing counter stored at `cluster/epoch` in etcd.
It advances ONLY when a node is fenced (EC2 StopInstances succeeds). This ensures
a fenced node — whose local epoch is now behind — cannot reacquire locks even if
it restarts and reconnects. Clean shutdown does NOT increment the epoch.

See `docs/epoch-mechanism.md` for the full design rationale.

## Session & Fencing

Every cluster-agent maintains an etcd session lease (15s TTL, keepalive every 5s).
All keys created by the agent (member key, lock keys, journal slots) are attached
to this lease. If the agent crashes or the node becomes unreachable, the lease
expires and all keys are automatically deleted by etcd.

Surviving agents watch the member key prefix. When a member key disappears
(lease expiry), the survivors race to claim the fencing key via CAS. The winner
calls the EC2 API to stop the failed instance and detach its EBS volume. Once
fencing completes, the winner:

1. Increments the cluster epoch (preventing the fenced node from ever rejoining
   unnoticed)
2. Signals recovery-ok to the kernel so GFS2 can replay the failed node's journal

With colocated etcd, the fenced node's etcd member is also dead. The remaining
cluster auto-removes the dead member via etcd's built-in failure detection.

## Key Constraints

- **Fencing is EC2 only** — no STONITH/IPMI. Never grant `ec2:TerminateInstances`.
- **Idle nodes are never fenced** — session keepalive is unconditional.
- **No node-to-node monitoring** — etcd Watch + session expiry are the sole liveness signals.
- **Journals are on-disk only** — GFS2 manages journal placement; etcd only coordinates
  which journal slot each node claims.
- **Fencing token = etcd revision** — stored in kernel, validated on every grant to
  prevent stale lock usage after a crash.
- **Cluster epoch** — incremented on fence, validated on mount and every lock grant.
  A fenced node with a stale epoch is rejected before any lock I/O.
- **Conditional yield flag** — agent sends LOCK_YIELD to kernel; kernel suppresses
  reacquire attempts only when the glock is in UNLOCKED state (conversions pass through).
  Cleared by YIELD_CLEAR after handoff completes. Not auto-cleared.
- **BAST watch per held lock** — `trackHeldLock` spawns a goroutine that watches
  `/locks/bast/{type}/{num}` and triggers yield on contention.
- **etcd colocated** — etcd runs on compute nodes, managed by the agent's membership
  package. No dedicated etcd instances or NLB. See `docs/plan/etcd-compute-colocation.md`.
