# QAttach

etcd-backed distributed lock manager (DLM) replacement for GFS2 on EBS Multi-Attach.

## Architecture

```
lock_etcd (kernel module, lm_lockops impl) ←Netlink→ cluster-agent (Go daemon) ←gRPC→ etcd (3-node Raft)
```

- **`lock_etcd`** — kernel module (C) implementing GFS2's `lm_lockops`. Replaces `lock_dlm`.
- **`cluster-agent`** — Go userspace daemon (one per compute node). Owns etcd, fencing, Netlink server.
- **etcd** — fixed 3-node Raft cluster behind internal NLB. Source of truth for membership, glocks, fencing.
- **GFS2** — unchanged on-disk format. Journals on-disk only (not in etcd).
- **EBS io2 Multi-Attach** — one volume per AZ shared by all compute nodes.

## Key constraints

- Fencing: EC2 API (`StopInstances`/`DetachVolume`), **not** STONITH/IPMI. Never grant `ec2:TerminateInstances`.
- Session lease TTL=15s, keepalive every 5s. Idle nodes are never fenced.
- Fencing token = etcd revision of the lock key, validated on every request.
- No node-to-node monitoring — etcd Watch + session expiry are the sole liveness signals.
- Glock mode mapping: EX→EX, SH→PR, DF→CW, UN→delete key.
- etcd keys: `/cluster/members/{id}`, `/cluster/fencing/{id}`, `/cluster/epoch`, `/locks/glock/{type}/{number}`.

## Build & test

```bash
go build ./...          # build cluster-agent
go test ./...           # 20 unit tests (no infra needed)
go vet ./...            # static analysis
```

## Full deployment workflow

Run these in order from the repo root:

```bash
# 1. Provision AWS infrastructure (VPC, EC2, EBS, NLB)
QATTACH_KEY_NAME=muhamad-keypair scripts/infra/create-infra.sh

# 2. Install etcd cluster with mTLS
scripts/infra/setup-etcd.sh

# 3. Install agent + kernel module + GFS2 on compute nodes
scripts/infra/setup-compute.sh

# 4. Run end-to-end tests
scripts/infra/run-full-test.sh

# 5. Tear down everything
scripts/infra/destroy-infra.sh --force
```

Infra state is saved to `infra-state.json` so scripts can resume after interruption.

## Environment (from `docs/awscli_info.txt`)

```
region: eu-west-1     (was us-east-1 in docs, actual: eu-west-1)
az: eu-west-1b
key_pair_name: muhamad-keypair
pem_path: ~/.ssh/id_ed25519
cluster_name: mycluster
aws_profile: default
```

Set overrides via env: `QATTACH_KEY_NAME`, `QATTACH_PEM_PATH`, `QATTACH_AZ`, `QATTACH_CLUSTER`, etc.

## File map

| Path | Purpose |
|------|---------|
| `cmd/cluster-agent/` | CLI entrypoint |
| `internal/etcd/` | etcd client (mTLS, sessions, CAS, Watch) |
| `internal/netlink/` | Raw AF_NETLINK server (kernel↔userspace) |
| `internal/lock/` | Glock request handler (acquire, release, watch-and-retry) |
| `internal/fencing/` | Member Watch, CAS race, EC2 fencing |
| `internal/identity/` | IMDSv2 instance ID/IP/AZ discovery |
| `internal/lifecycle/` | ASG terminating lifecycle hook |
| `internal/config/` | Configuration defaults |
| `internal/signal/` | SIGTERM/SIGINT handling |
| `kernel/` | `lock_etcd` kernel module (C, lm_lockops impl) |
| `pkg/protocol/` | Shared types (glock modes, Netlink messages, etcd keys) |
| `scripts/infra/` | AWS infra provisioning, etcd setup, compute setup, e2e tests |
| `scripts/` | GFS2 format, mount, journal management, module loader |
| `scripts/test/` | Standalone test suite, partition sim, fencing test, glock monitor |
| `docs/` | Design plan, AWS setup, env info |

## Design doc

`docs/general_plan.md` — 843 lines, covers every architectural decision, IAM policy, etcd key schema, phased plan, test matrix, and all reference URLs.

## Current status

### Working

- Single-key lock model (one key per lock, JSON holder array)
- **Cross-node concurrent writes** — both nodes write files, both nodes see them
- **Cross-node reads** — file written on node0 visible on node1 (and vice versa)
- **Multi-round concurrent append** — sequential writes from both nodes interleave correctly
- BAST delivery end-to-end (via `gfs2_glock_cb`)
- **Proactive BAST watch** — agent watches `/locks/bast/{type}/{num}` per held lock; sends BAST + LOCK_YIELD on arrival (`internal/lock/manager.go:148-171`)
- **LOCK_YIELD kernel mechanism** — yield flag set on `LM_ST_UNLOCKED`, auto-cleared after one suppression (`kernel/lock_etcd_lock.c:96,112`)
- Atomic handoff (holder→waiter reservation via `/next` key)
- Self-contention handling with other holders
- Journal ID CAS assignment
- Go↔C struct padding
- Agent PID re-registration on restart
- **Custom kernel build pipeline** — `scripts/kernel/launch.sh` compiles kernel 6.18.35 with lock_etcd in-tree, NVMe built-in, uploads to S3

### Not yet working

- **Large file I/O hangs** (e.g., `dd bs=1M count=5`) — sustained writes cause lock starvation. The BAST watch releases the lock from etcd, but the kernel yield flag only suppresses *one* reacquire; GFS2 may reacquire faster than the waiter can claim it, creating a livelock.
- GFS2 metadata locks EX→SH demotion not guaranteed during heavy I/O
- `mkfs.gfs2` doesn't recognize `lock_etcd` protocol — must format with `lock_dlm`, mount with `lockproto=lock_etcd`

### Kernel deployment workflow

The custom kernel (6.18.35, NVMe built-in, lock_etcd in gfs2.ko) must be deployed **before** `setup-compute.sh`:

```bash
# 1. Build kernel (optional — prebuilt archive is on S3)
scripts/kernel/launch.sh
# Teardown builder instance after upload

# 2. Create infra
QATTACH_KEY_NAME=muhamad-keypair scripts/infra/create-infra.sh

# 3. Setup etcd
scripts/infra/setup-etcd.sh

# 4. Deploy custom kernel to compute (SCP 784MB archive, extract, grubby, reboot)
scp /tmp/kernel-6.18.35-custom.tar.gz ec2-user@<ip>:/tmp/
# On compute: tar xzf -C /, grubby --add-kernel ..., reboot

# 5. Build agent locally, push to compute, start systemd unit
# 6. Format GFS2 on node1: mkfs.gfs2 -p lock_dlm -t <cluster>:sharedfs -j 2
# 7. Mount both: mount -t gfs2 -o lockproto=lock_etcd,locktable=<cluster>:sharedfs,noatime
```

### Test workflow quirks

- **The cluster-agent systemd unit must NOT have `ExecStop=umount`** — it bricks agent restarts. If GFS2 is mounted and the unit has an ExecStop umount, systemd will try to unmount on restart, hang because the filesystem is busy, and the agent will never come back.
- **Agent restart requires a reboot if GFS2 is mounted** when ExecStop includes umount. Removing ExecStop fixes this — the agent can restart cleanly while GFS2 stays mounted.
- **Nodes with hung GFS2 need force-terminate, not graceful shutdown** — graceful shutdown tries to unmount, which hangs. Use `aws ec2 stop-instances --force` or `aws ec2 terminate-instances`.
- **`create-infra.sh` overwrites `~/.ssh/id_ed25519`** when creating a new keypair. Use `QATTACH_KEY_NAME=muhamad-keypair` with an existing keypair. The SSH agent must hold the private key (the file itself may be stale).
