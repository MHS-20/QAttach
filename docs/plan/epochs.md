# Epoch Counter — Implementation Plan (Fully Implemented)

> **Status: Complete** — all 5 phases implemented. See `docs/epoch-mechanism.md` for the
> conceptual design and rationale. This document captures the original implementation
> plan and serves as a reference for what was changed.

## State before implementation

## Goal

The epoch is a monotonically-increasing counter that advances only after a fence
event. Every node stores its last-known epoch; any operation (mount, lock acquire)
is rejected if the cluster epoch has advanced past the node's last-known value
(meaning the node was fenced or missed a fencing event).

## Epoch lifecycle

```
Epoch=0 (initial) ──► Fence node A ──► Epoch=1 ──► Fence node B ──► Epoch=2 ...
                       │                    │
                       ▼                    ▼
              Node A's epoch stale    Node B's epoch stale
              → can't remount        → can't remount
              → lock requests denied → lock requests denied
```

## Implementation

### Phase 1: Mount-time epoch acquisition

1. Kernel sends `MOUNT_REQ` → agent acquires current `cluster/epoch` revision
2. Agent sends `MOUNT_RESP` with `epoch` field (add to `MountResponse` struct)
3. Kernel stores `ls_epoch` in `gfs2_sbd` private area
4. Every `LOCK_REQ` includes the node's known epoch

### Phase 2: Lock-grant epoch validation

1. Agent receives `LOCK_REQ` with `node_epoch` field
2. Agent reads current `cluster/epoch` from etcd
3. If `cluster_epoch > node_epoch`: node was fenced → deny lock with `DenyReasonStaleEpoch`
4. Kernel receives deny → returns `-ESTALE` to GFS2 → GFS2 withdraws the node
5. If `cluster_epoch == node_epoch`: grant lock normally

### Phase 3: Clean shutdown

1. On graceful shutdown, agent does NOT increment epoch
2. Agent deregisters from `/cluster/members/{self}`
3. Agent removes self from etcd cluster membership
4. Epoch remains unchanged — surviving nodes continue normally
5. On restart (if epoch matches), node can rejoin immediately

### Phase 4: Crash recovery

1. Node B crashes → lease expires → `/cluster/members/B` deleted
2. Node A wins fencing CAS → EC2 stops B → **increments epoch**
3. Node A signals recovery-ok to kernel with new epoch
4. Kernel replays B's journal (standard GFS2 recovery)
5. Node B restarts later:
   a. Agent connects to etcd
   b. Reads `cluster/epoch` → sees it advanced past its last-known epoch
   c. Agent refuses to mount GFS2 (or kernel rejects after mount with `-ESTALE`)
   d. Operator must clear node B's state before rejoining

### Phase 5: Bootstrap epoch validation

1. First node bootstraps: writes `cluster/epoch = 0` (if key doesn't exist)
2. Joining nodes: read current epoch, store locally
3. Full cluster restart (cold start): all nodes come up, epoch unchanged → no rejection
4. Partial restart after fence: fenced nodes rejected, survivors continue

## Protocol changes

### `MountResponse` — add epoch field
```c
struct letcd_mount_resp {
    u32 request_id;
    s32 jid;
    s64 epoch;       // NEW: cluster/epoch revision at mount time
};
```

### `LockRequest` — add node epoch field
```c
struct letcd_lock_req {
    u64 request_id;
    u32 glock_type;
    u64 glock_number;
    u32 requested_mode;
    s64 node_epoch;  // NEW: node's last known epoch
    u32 __pad;
};
```

### New deny reason
```
DenyReasonStaleEpoch = 4  // in pkg/protocol/netlink.go
```

## etcd key behavior

| Event | `cluster/epoch` action |
|-------|----------------------|
| First node bootstrap | Put key if doesn't exist (revision=1) |
| Normal operation | No change |
| Fence (crash of peer) | `IncrementEpoch()` → Put key (revision=N+1) |
| Clean shutdown | No change |
| Full cluster restart | No change (data survives in etcd WAL) |

## Kernel changes

- `lock_etcd_mount.c`: parse `epoch` from mount response, store in `ls_epoch`
- `lock_etcd_lock.c`: include `ls_epoch` in lock request
- `lock_etcd_glock.c`: handle `DenyReasonStaleEpoch` → trigger GFS2 withdraw
- `lock_etcd_internal.h`: add `ls_epoch` to mount context

## Agent changes

- `internal/lock/manager.go`: `HandleLockRequest` reads epoch, compares, denies if stale
- `internal/lock/manager.go`: `HandleMountRequest` returns epoch in response
- `internal/membership/bootstrap.go`: on first bootstrap, write epoch key

## Fencing integration (already implemented)

The only epoch increment point is inside `fencer.go:executeFencing()`, after
successful EC2 fencing. This is correct — epoch represents "someone was fenced",
not "someone left voluntarily".

## Risks

- **Epoch drift on cold restart**: If all nodes restart simultaneously, epoch is
  unchanged and all nodes rejoin cleanly. This is correct behavior — no one was
  fenced during the outage. GFS2 journal replay handles any unclean unmount.
- **Split-brain with epoch**: If two nodes form a partition and both think they
  have quorum, the epoch doesn't prevent split-brain — etcd quorum does. Epoch
  only prevents a fenced node from rejoining unnoticed.
- **Epoch key deletion**: Accidental deletion of `cluster/epoch` causes all
  nodes to see epoch=0 (or the key being missing). Mitigation: treat missing key
  as epoch=0 and handle identically.

## Non-goals

- Epoch is NOT a fencing token replacement. The fencing token (etcd revision of
  the lock key) is validated per-lock. Epoch is a coarse "have you been fenced?"
  check at mount/lock-request time.
- Epoch is NOT incremented on every lock grant. That would be a lease, not an
  epoch, and would create unnecessary write load.
- Epoch is NOT used for lock ordering or fairness. That's the kernel's ordered
  queue (`letcd_ordered_drain`).
