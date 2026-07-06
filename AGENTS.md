# QAttach

etcd-backed distributed lock manager (DLM) replacement for GFS2 on EBS Multi-Attach.

## Architecture

```
lock_etcd (kernel module, lm_lockops impl) ←Netlink→ cluster-agent (Go daemon) ←etcd v3→ etcd (colocated, 3-node Raft)
```

- **`lock_etcd`** — kernel module (C) implementing GFS2's `lm_lockops`. Built in-tree as part of `gfs2.ko` via `scripts/kernel/patch-kernel.py` (patches GFS2 source to call lock_etcd init/cleanup). Replaces `lock_dlm`.
- **`cluster-agent`** — Go userspace daemon (one per compute node). Handles etcd membership, fencing, Netlink server. Agent can start without the kernel module (netlink server is non-fatal).
- **etcd** — 3-node Raft cluster colocated on compute nodes. Agent manages bootstrap/join/member-remove (`internal/membership/`). No dedicated etcd instances or NLB.
- **GFS2** — unchanged on-disk format. Journals on-disk only (not in etcd).
- **EBS io2 Multi-Attach** — one volume per AZ shared by all compute nodes.

## Key constraints

- Fencing: EC2 API (`StopInstances`/`DetachVolume`), **not** STONITH/IPMI. Never grant `ec2:TerminateInstances`.
- Session lease TTL=15s, keepalive every 5s. Idle nodes are never fenced.
- Fencing token = etcd revision of the lock key, validated on every request.
- No node-to-node monitoring — etcd Watch + session expiry are the sole liveness signals.
- Glock mode mapping: EX→EX, SH→PR, DF→CW, UN→delete key.
- etcd keys: `/cluster/members/{id}`, `/cluster/fencing/{id}`, `/cluster/epoch`, `/cluster/journals/{jid}`, `/locks/glock/{type}/{number}`, `/locks/glock/{type}/{number}/next` (handoff reservation), `/locks/bast/{type}/{number}` (BAST request signal).
- `mkfs.gfs2` doesn't recognize `lock_etcd` — format with `-p lock_dlm`, mount with `-o lockproto=lock_etcd`.

## Build & test

```bash
go build ./...          # build cluster-agent (alias: make build-agent → bin/cluster-agent)
go test ./...           # 5 packages with tests (no infra needed)
go vet ./...            # static analysis
make build-module       # kernel module (requires kernel headers)
make lint               # requires golangci-lint (not in go.mod)
```

Single-package test: `go test ./internal/netlink/`

## Deployment workflow

Run in order:
```bash
# 1. Build kernel (optional — prebuilt on S3). Teardown instance after upload.
scripts/kernel/launch.sh
# 2. Provision AWS infra
QATTACH_KEY_NAME=muhamad-keypair scripts/infra/create-infra.sh
# 3. Install etcd + agent + kernel module + GFS2 on compute nodes
scripts/infra/setup-compute.sh
# 4. End-to-end test
scripts/infra/run-full-test.sh
# 5. Teardown
scripts/infra/destroy-infra.sh --force
```

Infra state saved to `infra-state.json` (gitignored). Env overrides: `QATTACH_KEY_NAME`, `QATTACH_PEM_PATH`, `QATTACH_AZ`, `QATTACH_CLUSTER`, etc. Region: `eu-west-1`, AZ: `eu-west-1b`.

## Critical gotchas

### Go struct padding for Netlink
Go netlink message structs in `pkg/protocol/netlink.go` have explicit padding fields (`PadGrant`, `PadDeny`, `PadMnt`, `Pad`) to match C struct layout in `kernel/letcd_netlink.h`. If you modify either side, check `binary.Size(T{})` matches `sizeof(struct letcd_*)`.

### Dual `letcd_netlink.h`
The Netlink protocol header is duplicated at `pkg/protocol/letcd_netlink.h` and `kernel/letcd_netlink.h`. **Keep both in sync** when adding message types or changing structs.

### Agent restart with GFS2 mounted
The cluster-agent systemd unit must **not** have `ExecStop=umount` — it bricks agent restarts (systemd tries to unmount, hangs because filesystem is busy). If GFS2 is hung, use `aws ec2 stop-instances --force` (not graceful shutdown).

### Kernel packaging
The custom kernel (6.18.35, NVMe built-in, lock_etcd in gfs2.ko) must be deployed before `setup-compute.sh`. The S3 archive may have stale `gfs2.ko` — verify the module path in the tar matches what compute nodes expect (`/lib/modules/6.18.35/` not a full distro version path).

## File map

| Path | Purpose |
|------|---------|
| `cmd/cluster-agent/main.go` | CLI entrypoint |
| `internal/{etcd,fencing,identity,lifecycle,lock,membership,netlink,config,signal}/` | Go agent packages |
| `pkg/protocol/` | Shared Go/C types (glock modes, Netlink messages, etcd keys) |
| `kernel/` | `lock_etcd` kernel module (C, lm_lockops impl, built into gfs2.ko) |
| `scripts/infra/` | AWS infra provisioning, etcd setup, compute setup, e2e tests |
| `scripts/kernel/` | Kernel build pipeline (`launch.sh`, `patch-kernel.py`, `teardown.sh`) |
| `docs/` | Architecture, epoch mechanism, known limitations |
| `docs/operational/general_plan.md` | 842-line design doc covering all architectural decisions |

## Known bugs (blocking e2e)

### CRITICAL: Lock mode constants inverted
GFS2 kernel `LM_ST_SHARED=1`, `LM_ST_EXCLUSIVE=3`. But `pkg/protocol/glock.go` defines `LockModeExclusive=1`, `LockModeShared=3` — **swapped**. The kernel's `letcd_lock` sends `req_state` directly from GFS2 (`req.requested_mode = req_state`), so the agent receives GFS2 standard values. But `LockModeToEtcd(1)` returns `"EX"` (should be `"PR"`), and `LockModeToEtcd(3)` returns `"PR"` (should be `"EX"`). Result: all SH locks are stored as exclusive in etcd, all EX locks as shared. Quotad SH polling works only because it's single-node; cross-node access would immediately break. Same bug in `kernel/letcd_netlink.h` defines (`LETCD_LM_ST_EXCLUSIVE=1`, `LETCD_LM_ST_SHARED=3`).

**Fix**: Swap constants in `glock.go` and `letcd_netlink.h` to match GFS2: `SH=1, EX=3, DF=2`.

### CRITICAL: Ordered list never cleaned on unmount
`letcd_ordered_list` in `lock_etcd_lock.c` is a static global list. When mount fails mid-way (e.g. agent returns WAIT for journal RG demote), the ordered entry stays in the list with `completed=false`. Since the list is static, it persists across mount/unmount cycles. Every subsequent `ord=` completion prints `ORD-NEXT ord=0x020000000000c395` but the stuck entry never clears. This blocks any new lock request whose order key is higher than the orphaned entry's.

**Fix**: Add `letcd_ordered_cleanup()` called from `lock_etcd_unmount()` to drain and wake all waiters, and `list_del_init` all entries.

### BUG: Agent starts before gfs2 module after reboot
After reboot, systemd starts cluster-agent before gfs2 module is loaded. Agent logs: `"netlink server unavailable (kernel module not loaded?): netlink socket: protocol not supported"`. Mount then fails with `"Transport endpoint is not connected"`. Restarting agent after `modprobe gfs2` fixes it.

**Fix**: Add `ExecStartPre=/sbin/modprobe gfs2` to `cluster-agent.service`, or ensure `setup-compute.sh` adds a systemd dependency.

## Additional docs

- `docs/epoch-mechanism.md` — cluster epoch for fencing rejection
- `docs/plan/etcd-compute-colocation.md` — etcd colocation design
- `todo.md` — current status and remaining issues (kernel packaging pipeline broken)
