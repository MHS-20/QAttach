# Epoch Mechanism

## Why epochs are necessary

In a distributed lock manager backed by etcd, the fencing token (etcd revision
of the lock key) prevents a single lock from being used with stale cache. But it
doesn't cover a critical scenario: **a fenced node reconnects and acquires new
locks after being kicked out.**

Consider this sequence without epochs:

```
1. Node A and Node B hold locks, both healthy
2. Node B crashes — session lease expires — member key deleted
3. Node A fences Node B via EC2 StopInstances
4. Node B stops. GFS2 journal replay on Node A recovers B's work.
5. Node B restarts (EC2 auto-recovery or operator action).
6. Node B's agent reconnects to etcd, creates a new session.
7. Node B mounts GFS2 — gets a new journal slot — starts acquiring locks.
8. Node B now holds locks on the same filesystem as Node A,
   with NO memory of being fenced.
```

Without an epoch, step 7-8 succeeds silently. Node B has no way to know it was
fenced — the fencing token only covers locks held *before* the crash, not locks
acquired *after* reconnection.

**The epoch solves this**: it's a cluster-wide monotonically-increasing counter
that advances on every fence. Every node learns the current epoch at mount time
and presents it with every lock request. A fenced node whose epoch is behind the
cluster epoch is rejected on every lock attempt.

## How it works

### Data model

A single etcd key: `cluster/epoch`. Its value is irrelevant — the etcd revision
of the key (ModRevision) *is* the epoch. Every `Put` on this key produces a new,
globally-unique, strictly-increasing revision.

```
cluster/epoch  (value="0", mod_revision=3)
↓ fence Node B
cluster/epoch  (value="1", mod_revision=8)
↓ fence Node C
cluster/epoch  (value="2", mod_revision=12)
```

Using etcd revision rather than a counter value avoids:
- Race conditions from read-modify-write (Increment-and-Get is atomic in etcd)
- The need for CAS loops
- Duplicate epoch values if two nodes fence simultaneously (impossible — CAS
  ensures only one winner)

### Lifecycle

```
Bootstrap
  Node 0 starts → InitEpoch() CAS: if key doesn't exist, create it
  → epoch revision = 3 (first write after member registrations)

Mount (per node)
  kernel sends MOUNT_REQ
  agent calls GetEpoch() → reads cluster/epoch ModRevision → returns in MOUNT_RESP
  kernel stores epoch locally (letcd_mount_ctx.mount_epoch)

Lock Acquire (every request)
  kernel sends LOCK_REQ with node_epoch field
  agent checks: if node_epoch > 0 && cluster_epoch > node_epoch:
    → deny with DenyReasonStaleEpoch (4)
    → kernel returns -ESTALE to GFS2
    → GFS2 withdraws the node (marks filesystem inconsistent, requires remount)

Fence (crash of peer)
  surviving node's fencer executes EC2 StopInstances
  on success → IncrementEpoch() → Put cluster/epoch
  → next lock request from fenced node (if it restarts) will have stale epoch
  → denied

Clean Shutdown
  agent deregisters from etcd, removes self from membership
  epoch is NOT incremented
  node can restart and rejoin immediately (epoch matches)
```

### Protocol changes

| Direction | Message | Field | Purpose |
|-----------|---------|-------|---------|
| agent → kernel | MountResponse | `s64 epoch` | Cluster epoch at mount time |
| kernel → agent | LockRequest | `s64 node_epoch` | Node's last-known epoch |
| agent → kernel | LockDeny | `reason=4` | DenyReasonStaleEpoch |

### Backward compatibility

- `node_epoch = 0`: kernel doesn't support epochs (pre-epoch kernel or not yet
  mounted). Agent accepts these requests without epoch validation.
- `node_epoch > 0`: epoch-aware kernel. Agent validates against `cluster_epoch`.
  If `cluster_epoch > node_epoch`: deny. If `cluster_epoch == node_epoch`: proceed.

This means the epoch mechanism can be deployed incrementally — old kernels work
alongside new ones during a rolling upgrade.

### Edge cases

**Full cluster restart (all nodes reboot simultaneously)**
Epoch is unchanged. All nodes reconnect with the same epoch. This is correct —
no one was fenced during the outage. GFS2 journal replay handles any unclean
unmounts.

**First node bootstrap with no prior epoch**
CAS creates the key at revision N. The first node learns epoch=N at mount.
This is the baseline epoch.

**Network partition (two halves think they're the cluster)**
etcd Raft prevents split-brain. The minority partition cannot form quorum, so
it cannot write to etcd (including incrementing epoch). The majority continues
normally. When the partition heals, the minority nodes reconnect and see the
unchanged epoch — no fencing occurred.

**Operator accidentally deletes `cluster/epoch`**
Treated as epoch=0. All nodes with epoch>0 (which is all mounted nodes) will
fail the epoch check on next lock request — because 0 > 0 is false, wait...
Actually: if the key is deleted, `GetEpoch()` returns 0. A mounted node has
epoch=N from mount time. The agent compares `cluster_epoch (0) > node_epoch (N)`:
false. So no nodes are rejected. But this is correct — deleting the epoch key
is a catastrophic event that requires operator intervention anyway. In practice,
etcd RBAC prevents this.

## Relationship to fencing token

| Mechanism | Scope | When checked | What it prevents |
|-----------|-------|-------------|-----------------|
| Fencing token (lock revision) | Per-lock | On lock re-grant | Stale lock cache after crash |
| Cluster epoch | Cluster-wide | On mount + every lock grant | Fenced node reacquiring ANY lock |

The fencing token says "this specific lock is still valid for you." The epoch
says "you have not been fenced since you joined this cluster." Both are needed.
