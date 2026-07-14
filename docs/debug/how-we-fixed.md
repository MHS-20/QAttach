# Deadlock & Livelock Fixes (v0.0.4)

## Root Cause

Multi-node GFS2 concurrent writes deadlocked due to three interacting problems:

1. **Holder-reacquire race**: when a holder released and immediately reacquired a lock via
   `self-contention`, the waiter's etcd Watch would never fire before the holder's CAS re-grabbed
   the key.

2. **Zombie glock holders**: the async grant window between `letcd_lock` sending a netlink request
   and the agent responding with GRANT left holders in an orphaned state (`p:0` in glock dump).
   `run_queue` found these zombies via `find_first_holder()` and returned without calling
   `lm_lock`, blocking all subsequent glock state transitions.

3. **Silent BAST gap**: a converting node never BASTed inactive third-party PR holders. With 3
   nodes mounted, the inactive third node held cached PR from mount-time directory scanning,
   and neither contending node asked it to release. The conversion waited indefinitely.

## Fixes Applied

### 1. In-place conversion (ConvertLock)

Removed the release-then-reacquire self-contention path. When a node already holds PR and needs
EX, `ConvertLock` atomically updates the etcd entry from PR→EX without releasing. If conflicting
holders exist, it queues the conversion and polls until they release. This eliminates the
holder-reacquire race window.

**Files**: `internal/etcd/client.go` (ConvertLock), `internal/lock/manager.go` (watchForConversion)

### 2. Polling replaced etcd Watch

etcd Watches silently failed to deliver events with a 3-node colocated cluster. Replaced all
`Watch` calls with polling loops (200ms for new lock acquisition, 1s for conversion polling).
This adds negligible etcd load (1-5 GET/s) but eliminates the silent failure mode.

**File**: `internal/lock/manager.go` (watchForLock, watchForConversion)

### 3. Inline-SH for local-only lock types

GFS2 glock types 1 (nondisk), 5 (IOPEN), and 8 (quota) are per-node metadata that DLM grants
without remote coordination. Added a fast-path in `letcd_lock` that calls `gfs2_glock_complete`
inline for SH acquisitions on these types, bypassing the netlink+etcd round-trip entirely.
This eliminates mount-time zombie holders because the grant is synchronous — no async window.

**File**: `kernel/lock_etcd_lock.c` (INLINE-SH fast-path)

### 4. BAST all conflicting PR holders during conversion

When `ConvertLock` detects conflicting PR holders (including on inactive third nodes), it
writes a BAST key to each holder's etcd namespace. The holder's `watchBastAndYield` goroutine
fires, sends a kernel BAST (`gfs2_glock_cb(UN)`), and the kernel demotes. `HandleLockRelease`
then removes the PR entry from etcd, clearing the conflict for the converter.

**Files**: `internal/lock/manager.go` (HandleLockRequest, watchForConversion)

### 5. ReleaseLock CAS retry

Multi-holder `ReleaseLock` used a single CAS attempt. When two nodes released simultaneously,
one CAS failed silently and the key retained stale entries. Changed to infinite retry: re-read
the value on version mismatch and CAS again until success.

**File**: `internal/etcd/client.go` (ReleaseLock)

### 6. Yield suppression removed

The original `letcd_lock` had a yield-suppression path that called `gfs2_glock_complete(gl, 0)`
(UN mode), creating zombie holders. Removed entirely along with the yield hash table, netlink
messages, and the may_grant/run_queue kernel patches.

**Files**: `kernel/lock_etcd_lock.c`, `kernel/lock_etcd_glock.c`, `kernel/letcd_netlink.h`,
`kernel/lock_etcd_netlink.c`, `scripts/kernel/patch-kernel.py`

### 7. Infra fixes

- `depmod -a` after custom kernel reboot so `modprobe gfs2` finds the module
- `modprobe gfs2 || true; sleep 1` before mount to handle module init race
- Stale etcd cleanup before reboot to prevent 6-member split-brain
- Stale etcd cleanup in setup-compute.sh before agent start

**Files**: `scripts/infra/deploy-kernel.sh`, `scripts/infra/setup-compute.sh`

## How DLM Avoids These Issues

DLM has no equivalent problems because:

- **Synchronous local grants**: `do_request` grants a local lock and queues the CAST callback
  inside the same function call. There's no async window.
- **Convert queue**: DLM moves a converting lock to the convert queue (`lkb_status = CONVERT`)
  instead of releasing and reacquiring. The lock stays tracked.
- **BAST to all blockers**: When a request or conversion can't be granted, DLM iterates the
  grant queue and sends BAST to every conflicting holder via `send_blocking_asts`.
- **No Watch bridge**: DLM's lock state is maintained in-kernel (the `dlm_lkb` structure).
  There's no userspace component that needs to observe key changes.

## Summary

| Problem | Fix | Type |
|---------|-----|------|
| Holder-reacquire race | ConvertLock (in-place conversion) | Agent |
| Silent watch failure | Polling instead of etcd Watch | Agent |
| Mount-time zombie holders | Inline-SH for types 1,5,8 | Kernel |
| Third-node PR blocking EX | BAST all conflicting holders | Agent |
| Multi-holder CAS race | ReleaseLock infinite retry | Agent |
| Yield suppression zombies | Removed yield entirely | Kernel |
