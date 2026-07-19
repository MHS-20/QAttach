# QAttach System Architecture

## Overview

QAttach replaces the DLM stack with an etcd-backed locking protocol. A custom
kernel module (`lock_etcd`) implements GFS2's `lm_lockops` interface and
communicates with a userspace Go daemon (`cluster-agent`) over AF_NETLINK.
etcd is colocated on each compute node.

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
```

## Components

### lock_etcd (kernel module)

Implements `lm_lockops`, built into `gfs2.ko`. Replaces `lock_dlm`.

- Register AF_NETLINK family 31 for agent communication
- Translate GFS2 glock requests into netlink messages
- Maintain pending-request table (request ID → glock)
- Maintain BAST lookup table (glock identity → glock for callbacks)
- Store fencing tokens (etcd revisions) in glock private data

### cluster-agent (Go daemon)

One per compute node. Bridge between kernel and etcd.

- etcd session lease (TTL 15s, keepalive 5s)
- Node registration under session lease
- Netlink message handling (lock, unlock, mount, unmount)
- Lock acquisition via single etcd Txn (`ProcessLock`)
- BAST watcher per held lock (`watchBastAndYield`)
- FIFO lock handoff (`HandoffRelease` + `/next` marker)
- Journal slot assignment via etcd CAS
- Fencing via EC2 API (StopInstances / DetachVolume)

### etcd (3-node Raft cluster)

Source of truth for all distributed state.

- `/cluster/members/{id}` — node membership
- `/cluster/fencing/{id}` — fencing CAS keys
- `/cluster/epoch` — cluster epoch counter
- `/cluster/journals/{jid}` — journal slot assignment
- `/locks/glock/{type}/{number}` — lock holders (JSON array)
- `/locks/glock/{type}/{number}/next` — FIFO handoff reservation
- `/locks/bast/{type}/{number}` — BAST request signal

## Data Flow

### Lock Acquire

```
GFS2 needs glock
  → letcd_lock(gl, mode)
    → UNLOCKED: send LOCK_REL, complete synchronously
    → TRY/TRY_1CB: complete with LM_OUT_TRY_AGAIN
    → normal: letcd_nl_send_msg(LOCK_REQ), return 0 (async)
    → agent: ProcessLock (single etcd Txn)
      → GRANTED: send GRANT, track lock, spawn bast watcher
      → CONTENDED: send WAIT, start retryProcessLock goroutine
```

### Lock Release

```
GFS2 releases glock
  → letcd_lock(gl, LM_ST_UNLOCKED)
    → letcd_nl_send_msg(LOCK_REL)
    → complete synchronously
    → agent: HandleLockRelease → HandoffRelease
      → atomically delete lock key + write /next for first waiter
```

### BAST (Blocking AST)

```
Node B: ProcessLock fails → contention
  → write bast key + waiter entry
  → send LOCK_WAIT to kernel
  → start retryProcessLock goroutine

Node A: watchBastAndYield fires on bast key
  → send BAST to kernel
  → GFS2: glock_cb → run_queue → do_xmote(UNLOCKED)
  → letcd_lock(UNLOCK) → LOCK_REL
  → agent: HandoffRelease → delete lock key + write /next
  → Node B's retry sees /next marker → acquires → GRANT
```

### Epoch Validation

```
Mount: kernel sends MOUNT_REQ → agent returns epoch
Lock grant: agent stores etcd revision as fencing token
Fenced node: epoch behind → all lock requests denied (DenyReasonStaleEpoch)
```

## Session & Fencing

Session lease (15s TTL, keepalive 5s). All keys bound to lease; auto-deleted on
expiry. Surviving agents watch member keys for deletion → CAS race for fencing
key → winner fences via EC2 API → increments epoch.

## Key Constraints

- Fencing: EC2 only (StopInstances / DetachVolume), never TerminateInstances
- Idle nodes never fenced — keepalive is unconditional
- No node-to-node monitoring — etcd Watch + session expiry only
- Journals on-disk only — etcd coordinates slot assignment
- Fencing token = etcd revision — validated on every grant
- FIFO handoff via /next marker — prevents holder-reacquire livelock
- BAST always sent on contention — holder's GFS2 decides demotion
