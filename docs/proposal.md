# QAttach — etcd-Backed Distributed Lock Manager for GFS2

## Overview

QAttach replaces the traditional DLM stack (Corosync + Pacemaker + `lock_dlm`)
used with GFS2 with an etcd-backed locking protocol. The system provides
distributed filesystem locking across EC2 compute nodes accessing a shared
EBS io2 Multi-Attach volume.

## Core Idea

A custom kernel module (`lock_etcd`) implements GFS2's `lm_lockops` interface.
Instead of communicating with a DLM daemon, it talks to a userspace Go daemon
(`cluster-agent`) over Netlink. The agent uses etcd v3 as the single source of
truth for lock state, membership, and fencing coordination. Block I/O goes
directly to the shared EBS volume.

```
lock_etcd (kernel, lm_lockops) ←Netlink→ cluster-agent (Go) ←gRPC→ etcd (colocated)
```

## Architecture

### Component Summary

| Layer | Component | Role |
|---|---|---|
| Filesystem | GFS2 | Cluster filesystem with journals, glocks, cache coherence |
| Lock module | `lock_etcd` (in gfs2.ko) | Implements GFS2's `lm_lockops`; delegates glock requests to agent |
| Transport | Netlink (family 31) | Bidirectional kernel↔userspace for lock requests, grants, BAST |
| Userspace | `cluster-agent` (Go) | etcd connectivity, lock acquisition/release, membership, fencing |
| Coordination | etcd v3 | Distributed KV store: lock state, membership, epoch, journals |
| Storage | EBS io2 Multi-Attach | Shared block device, one per AZ, attached to all compute nodes |
| Fencing | EC2 API | `StopInstances` / `DetachVolume` for failed nodes |

### Lock Flow (EX request)

```
Kernel (GFS2)                    cluster-agent                     etcd
─────                            ──────────────                    ────
gfs2_glock_nq(EX)
  → letcd_lock(EX)
    → NL_SEND LOCK_REQ ──────►   AcquireLock(Txn: CAS put key)
                                   → granted? GRANT ──► kernel
                                   → contended? WAIT + bast key
BAST watcher sees bast key
  → NL_SEND BAST(UN) ────────►
    → gfs2_glock_cb(UN)
      → letcd_lock(UN)
        → NL_SEND LOCK_REL ──►   ReleaseLock → delete key
                                   waiter's watchAndRetry sees DELETE
                                    → AcquireLock → GRANT ──► waiter kernel
```

### Key Design Decisions

- **etcd colocated** — one etcd instance per compute node (3-node Raft cluster). No dedicated etcd hosts, no NLB.
- **Fencing via EC2** — `StopInstances` and `DetachVolume` (never `TerminateInstances`). No STONITH/IPMI.
- **Session leases** — TTL=15s, keepalive every 5s. Lock keys bound to session lease; expire automatically if agent crashes.
- **Fencing token** — etcd revision of each lock key. Validated on every request to prevent stale-client use.
- **Epoch mechanism** — cluster-wide monotonically-increasing counter. Advances on every fence. Fenced nodes with stale epochs are rejected on reconnection.
- **Netlink transport** — kernel module communicates with agent via Netlink family 31. Bidirectional, no filesystem-based FIFO.

### Lock Modes

Glock mode mapping to etcd:

| GFS2 Mode | Kernel Value | etcd Mode | Meaning |
|---|---|---|---|
| `LM_ST_UNLOCKED` | 0 | key deleted | Release the glock |
| `LM_ST_EXCLUSIVE` | 1 | `EX` | Exclusive write access |
| `LM_ST_DEFERRED` | 2 | `CW` | Concurrent write (direct I/O) |
| `LM_ST_SHARED` | 3 | `PR` | Protected read (shared access) |

### etcd Key Layout

| Key Pattern | Purpose |
|---|---|
| `/cluster/members/{id}` | Node membership record |
| `/cluster/fencing/{id}` | Fencing token for each node |
| `/cluster/epoch` | Cluster epoch counter |
| `/cluster/journals/{jid}` | Journal slot assignment |
| `/locks/glock/{type}/{number}` | Lock holders (current state) |
| `/locks/bast/{type}/{number}` | BAST request signal (waiter→holder) |

### GFS2 Integration

`lock_etcd` is built **into** `gfs2.ko` — not as a separate module. The kernel
build pipeline (`scripts/kernel/launch.sh`) patches the kernel source tree to
register `lock_etcd` as a GFS2 locking protocol alongside `lock_dlm`.

Formatting uses `mkfs.gfs2 -p lock_dlm` (mkfs doesn't recognize `lock_etcd`).
Mounting uses `mount -o lockproto=lock_etcd`.

### Node Lifecycle

1. Bootstrap — agent determines if it's a new cluster or joining existing; manages etcd colocation
2. Mount — GFS2 registers with `lock_etcd`; agent assigns journal slot; cluster epoch acquired
3. Operation — glock requests flow through Netlink; agent mediates via etcd transactions
4. Shutdown — agent releases held locks, deregisters from membership
5. Failure — fencing via EC2 API when session lease expires; epoch incremented

## Sequences

### Bootstrap Sequence

```
Agent starts
  → reads --etcd-endpoints, --initial-cluster, --etcd-name
  → membership.Bootstrap():
      1. Check if local etcd is already healthy → skip
      2. Probe peer endpoints for an existing etcd cluster
         → found? joinExisting(): add self as etcd member, start local etcd
         → not found? check for existing data on disk → restart
         → no data: bootstrapNew(): start etcd as single-node, then add peers
  → RegisterNode(): Put /cluster/members/{instance_id} under session lease
  → GetEpoch(): read /cluster/epoch → store cluster epoch
  → netlink: register with kernel module (family 31)
  → ready — listening for lock requests
```

### Session Lease & Keepalive

```
Agent starts
  → concurrency.NewSession(etcd, TTL=15s)
     → background goroutine sends keepalive every 5s
     → all keys written with this lease (member, lock, journal)
  ↓
Agent operates: hold locks, process requests
  ↓
Agent crashes / network lost
  → keepalive stops
  → 15s later: session lease expires
  → etcd auto-deletes all keys under this lease:
       /cluster/members/{id}  — membership removed
       /locks/glock/{type}/{number}  — all locks released
       /cluster/journals/{jid}  — journal slot freed
  → surviving agents detect member deletion → fencing race
```

### File Creation Sequence

```
Process on Node A:
  open(/mnt/shared/newfile, O_CREAT)
    → VFS: do_filp_open → gfs2_atomic_open → gfs2_create_inode
      1. Acquire EX on parent directory inode glock
         → letcd_lock(EX) → agent AcquireLock → etcd CAS → GRANT
      2. Acquire EX on journal glock (own journal slot)
         → letcd_lock(EX) → GRANT
      3. Allocate new inode from resource group
         → letcd_lock(EX) on rgrp glock → GRANT
      4. Write directory entry + inode to journal
      5. Release all glocks → letcd_lock(UNLOCK) → agent ReleaseLock
    → newfile visible to all nodes

Contention case (Node B creates a file in same directory simultaneously):
  Node A holds EX on directory inode glock
  Node B requests EX → AcquireLock fails (Node A holds EX)
    → agent writes BAST key, sends LOCK_WAIT to kernel
  Node A's BAST watcher sees key
    → sends BAST(UNLOCK) to kernel → demotes lock → releases
  Node B's watchAndRetry sees lock key deleted
    → AcquireLock(EX) succeeds → GRANT → creates file
```

### Clean Shutdown Sequence

```
Agent receives SIGTERM / SIGINT
  → signal handler: cancel main context
  → deregister from etcd:
      1. MemberRemove(self) from etcd cluster
      2. Delete /cluster/members/{instance_id}
  → release all held locks:
      for each heldLock → delete from etcd holder array
  → close etcd session (revoke lease, all keys auto-deleted)
  → stop local etcd process
  → netlink: unregister (close socket)
  → exit 0
```

## Current Status

The system can format, mount, and serve basic single-node I/O through GFS2.
Cross-node lock contention (concurrent writes, metadata operations) exposes
a glock handoff issue that is under active investigation. See
`docs/debug/deadlock_issuelog.md` for the detailed technical history.
