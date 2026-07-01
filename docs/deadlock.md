# Multi-node Deadlock Analysis & Solutions

## The Problem

When two GFS2 nodes create files in the same directory simultaneously,
they deadlock.  Both need the same two locks acquired step by step:

```
Node 0: open("/mnt/shared/.x", O_CREAT)
  → needs dir inode EX (type=2, num=33384) — call it Lock A
  → needs rgrp EX      (type=3, num=32861) — call it Lock B

Node 1: open("/mnt/shared/.y", O_CREAT)
  → needs the SAME dir inode EX  (Lock A)
  → needs a rgrp EX              (Lock B, same or different RG)
```

The AB/BA deadlock:

```
Time  Node 0                          Node 1
────  ────────────────────────────    ────────────────────────────
  1   requests Lock A → granted       requests Lock B → granted
  2   requests Lock B → contended     requests Lock A → contended
  3   🔒 holds A, waits for B          🔒 holds B, waits for A
```

Node 0 holds A and needs B.  Node 1 holds B and needs A.  Neither
can release its held lock while waiting for the other lock — both
are required simultaneously to complete `open()`.

## Why DLM Avoids This

DLM daemons on every node communicate via TCP and share the global
lock dependency graph.  When Node 0 requests A and Node 1 requests B,
both daemons see the full picture and withhold one of the grants.
Our agent only sees etcd keys (granted locks), not pending requests.

## Attempted Solutions

### 1. BAST + Handoff + Compatibility Matrix

Node B requests lock, CAS fails, writes a bast key, holder watches
it, sends BAST to kernel.  Holder demotes, atomic handoff reserves
lock for waiter.

**Result: livelock.**  EX holder receives BAST(SH), releases, but
GFS2's glock work function immediately reacquires EX because it
still needs it before the waiter can CAS.  Ping-pong forever.

### 2. No BAST, Just Wait

Node B does LOCK_WAIT and watches for the lock key to be deleted.
Holder releases naturally when GFS2 completes its I/O.

**Result: deadlock.**  Same AB/BA pattern — natural release never
happens because both nodes hold one lock while waiting for the other.

### 3. Kernel-level Ordered Queue

Kernel module serialises lock requests within a node via a sorted
wait queue (`letcd_ordered_drain`).  Each node acquires A before B
because `orderKey(A) < orderKey(B)`.

**Result: deadlock persists.**  The queue only orders within a node.
Node 0 acquires A first, Node 1 acquires B first (its queue was
empty).  Cross-node, the AB/BA cycle remains.

## Current Solution: Agent-side Global Order

The agent now enforces the same global sort order across all nodes
by tracking the sort keys of every held lock:

```
lockOrderKey = (type << 56) | number
```

Before granting any lock, the agent checks whether the requesting
node already holds any lock with a HIGHER sort key.  If so, the
request is denied (`LOCK_DENY` with reason `STALE`) — GFS2 must
release the higher-key lock first.

**Why this breaks the cycle:**

```
Node 0: holds Lock A (key=0x20000000000082D8)
  → requests Lock B (key=0x30000000000080F1)
  → holdsHigherLock(0x3000...) = false  (A < B)
  → granted ✓

Node 1: holds Lock B (key=0x30000000000080F1)
  → requests Lock A (key=0x20000000000082D8)
  → holdsHigherLock(0x2000...) = true   (B > A — held!)
  → DENIED ✗
  → GFS2 must release B first, then retry A
  → B becomes available → Node 0 gets it → completes both → releases
  → Node 1 gets A → gets B → completes
```

No cycle — the agent stops Node 1 from acquiring in the wrong order.

**Caveat:** This relies on GFS2 retrying the lock after receiving
`LOCK_DENY` with reason `STALE`.  The kernel's `dispatch_lock_deny`
calls `gfs2_glock_complete(gl, -ESTALE)`, which tells GFS2 the
lock state is stale and it should retry after releasing higher locks.
