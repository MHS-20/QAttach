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
- Carry lock value blocks on EX unlock, down-conversion and grant
- Forward `lm_cancel`, and replay a failed node's journal on request

### cluster-agent (Go daemon)

One per compute node. Bridge between kernel and etcd.

- etcd session lease (TTL 15s, keepalive 5s)
- Node registration under session lease
- Netlink message handling (lock, unlock, cancel, mount, unmount, recovery result)
- Lock acquisition via single etcd Txn (`ProcessLock`)
- Conversion-deadlock detection (denies the later converter)
- BAST watcher per held lock (`watchBastAndYield`)
- FIFO lock handoff (`ReleaseLock` + `/next` marker)
- Journal slot assignment via etcd CAS, released on unmount
- Fencing via EC2 API (StopInstances / DetachVolume) and journal recovery

### etcd (3-node Raft cluster)

Source of truth for all distributed state.

- `/cluster/members/{id}` — node membership
- `/cluster/fencing/{id}` — fencing CAS keys
- `/cluster/epoch` — cluster epoch counter
- `/cluster/journals/{jid}` — journal slot assignment (persistent)
- `/cluster/recovery/{jid}` — recovery barrier
- `/locks/glock/{type}/{number}` — lock holders (JSON array, persistent)
- `/locks/glock/{type}/{number}/next` — FIFO handoff reservation
- `/locks/bast/{type}/{number}` — BAST request signal
- `/locks/lvb/{type}/{number}` — lock value block

## Data Flow

### Lock Acquire

```
GFS2 needs glock
  → letcd_lock(gl, mode)
    → UNLOCKED: send LOCK_REL (with LVB if EX), complete synchronously
    → otherwise: letcd_nl_send_msg(LOCK_REQ with flags and LVB), return 0 (async)
    → agent: ProcessLock (single etcd Txn)
      → GRANTED: send GRANT with LVB, track lock, spawn bast watcher
      → TRY and not grantable: DENY → LM_OUT_TRY_AGAIN (TRY_1CB sends one BAST)
      → CONTENDED: send WAIT, start retryProcessLock goroutine
        → conversion deadlock: DENY → LM_OUT_DEADLOCK, GFS2 unlocks and retries
        → lm_cancel: DENY → LM_OUT_CANCELED
```

### Lock Release

```
GFS2 releases glock
  → letcd_lock(gl, LM_ST_UNLOCKED)
    → letcd_nl_send_msg(LOCK_REL)
    → complete synchronously
    → agent: HandleLockRelease → publish LVB → ReleaseLock
      → remove own entry; if none remain, delete lock key + write /next
        for the first waiter in the same Txn
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
  → agent: ReleaseLock → delete lock key + write /next
  → Node B's retry sees /next marker → acquires → GRANT
```

### Epoch Validation

```
Mount: kernel sends MOUNT_REQ → agent returns epoch
Lock grant: kernel records the etcd revision; a changed revision on an
            inode glock means another node held it → cached pages dropped
Recovery: epoch incremented after a failed node's journal is replayed
```

Per-request epoch checks (`DenyReasonStaleEpoch`) are designed but not
implemented; see `docs/epoch-mechanism.md`.

## Session & Fencing

Session lease (15s TTL, keepalive 5s) for membership. Lock keys and journal
slots are persistent, so a crashed node's locks keep blocking conflicting
requests. Every mounted agent scans for journal slots whose owner is not a
live member → CAS on the fencing key → winner fences via EC2 API → raises the
recovery barrier (only NOEXP requests are granted) → purges the dead node's
locks → its kernel replays the journal → barrier and slot removed, epoch
incremented. `--fence-mode=none` skips fencing for the local test harness.

## Key Constraints

- Fencing: EC2 only (StopInstances / DetachVolume), never TerminateInstances
- Idle nodes never fenced — keepalive is unconditional
- No node-to-node monitoring — etcd Watch + session expiry only
- Journals on-disk only — etcd coordinates slot assignment
- Lock ownership outlives the session — released by unlock or by recovery, never by lease expiry
- FIFO handoff via /next marker — prevents holder-reacquire livelock
- BAST always sent on contention — holder's GFS2 decides demotion
