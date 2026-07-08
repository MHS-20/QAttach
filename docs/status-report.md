# QAttach — Status Report

July 2026

---

## What QAttach Is

QAttach is an etcd-backed distributed lock manager that replaces the DLM
(Corosync + Pacemaker + `lock_dlm`) stack traditionally used with GFS2.
A custom kernel module (`lock_etcd`) implements GFS2's `lm_lockops` interface
and communicates over Netlink with a Go userspace daemon (`cluster-agent`).
The agent uses a colocated 3-node etcd cluster as the distributed coordination
layer. Block I/O goes directly to a shared EBS io2 Multi-Attach volume.

See `docs/proposal.md` and `docs/architecture.md` for detailed component
descriptions.

---

## What Works

| Capability | Status |
|---|---|
| Kernel module builds and loads (`gfs2.ko` with `lock_etcd` in-tree) | Stable |
| `cluster-agent` builds, starts, connects to etcd | Stable |
| etcd colocation — agent bootstraps/joins/manages etcd on compute nodes | Stable (3-node deploy) |
| Custom kernel deployment pipeline (`launch.sh`, `deploy-kernel.sh`) | Stable |
| Infrastructure provisioning (`create-infra.sh`, `destroy-infra.sh`) | Stable |
| GFS2 format + mount on 3 compute nodes with `lockproto=lock_etcd` | Stable |
| Single-node GFS2 I/O (reads, writes, file creation) | Stable |
| Journal assignment (per-node journal slots in etcd) | Stable |
| Netlink transport (kernel↔agent bidirectional messaging) | Stable |
| Epoch mechanism (fencing-token validation, stale-node rejection) | Implemented |
| Fencing via EC2 API (`StopInstances` / `DetachVolume`) | Implemented |
| mTLS for etcd communication | Stable |

## What Does Not Work

| Issue | Severity | Description |
|---|---|---|
| **Cross-node concurrent I/O** | Blocking | Concurrent writes from two nodes to the same file hang. On investigation, the glock handoff mechanism (BAST → yield → waiter acquire) never activates because the locking glocks never reach the kernel module's `letcd_lock()` entry point. Processes block in `gfs2_glock_wait` inside GFS2's own glock state machine, before the lock manager is invoked. See `docs/debug/deadlock_issuelog.md`. |
| **Metadata operations from non-holder** | Blocking | `chmod`, `chown`, and similar metadata ops on a GFS2 mount hold by another node hang in `gfs2_qa_get` — the quota glock acquisition path. This glock is acquired internally by GFS2 without going through the lock manager. See `docs/debug/glock-hang-analysis.md`. |
| **Fencing without IAM role** | Dependency | EC2 compute nodes have no IAM role. Fencing calls (`StopInstances`, `DetachVolume`) fail with credential errors. The agents correctly detect peer failures but cannot execute fencing. |

## Root Cause Analysis

The concurrent I/O hang has been investigated extensively (`docs/debug/`).
Key findings:

1. **GFS2's glock state machine stalls before calling `lm_lock`.** Kernel
   debug probes confirm that `letcd_lock()` is never called for the glocks
   that processes are blocked on. Only periodic quotad locks (every 30s)
   reach the agent.

2. **The cross-node BAST mechanism never activates.** No BAST keys are
   written to etcd, no BAST notifications sent to holders, no yield flags
   set. The entire handoff pipeline is idle during concurrent operations.

3. **The issue is NOT in the agent or etcd layer.** The agent processes
   all lock requests that reach it correctly. etcd cluster is healthy.
   The problem is in the GFS2 glock layer — specifically, glocks are stuck
   in a `GLF_DEMOTE` state that prevents the work function from calling
   the lock manager.

4. **Multiple agent-side approaches were attempted** before this was
   understood: BAST+handoff, ordered queues, global lock ordering, atomic
   handoff, proactive BAST watches, persistent yield flags. None resolved
   the root cause because the real issue is kernel-side.

## Current Development Focus

Understanding why GFS2's glock state machine stalls: specifically, why
`do_xmote` returns early (via `find_first_holder()` check at line 776 of
`gfs2/glock.c`) without invoking `lm_lock`, and what makes the glock
remain in `GLF_DEMOTE` state indefinitely.

## Known Side-Issues

- **Kernel build pipeline**: `launch.sh` builds from the Amazon Linux kernel
  SRPM. NVMe and ENA must be forced built-in via `sed` hacks because
  `olddefconfig` reverts them. Module signature enforcement must be disabled
  for `gfs2.ko` to load.
- **S3 deployment**: Compute nodes have no IAM role, so the kernel tarball
  must be deployed via SCP (`deploy-kernel.sh --local-tarball`). The S3-based
  fallback is non-functional without a public bucket policy.
- **`setup-compute.sh` TLS certs**: Regenerating certs on re-run breaks
  existing etcd clusters. The script is idempotent only for initial deployment.
- **Kernel module path**: The custom kernel's modules go to
  `/lib/modules/<version>/` while the tarball may place them differently.
  A symlink is sometimes needed.

## Test Infrastructure

All deployment (create, setup, test, destroy) is scripted under
`scripts/infra/`. Tests cover GFS2 mount verification, etcd membership,
concurrent writes, cross-node visibility, agent restart, etcd health,
and kernel module load. See `AGENTS.md` for the full workflow.

---

*This report covers the state as of the main branch commit `8a8f3f3`.*
