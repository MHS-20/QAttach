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
- Cross-node reads (node1 reads files written by node0)
- BAST delivery end-to-end
- Atomic handoff (holder→waiter reservation via `/next` key)
- Self-contention handling with other holders
- Journal ID CAS assignment
- Go↔C struct padding
- Agent PID re-registration on restart

### Not yet working

- Node1 writes hang: GFS2 metadata locks EX→SH demotion not guaranteed

See `docs/etcd-schema.md` for the single-key holder-array key layout and `docs/bast-mechanism.md` for the atomic handoff design.

### Test workflow quirks

- **The cluster-agent systemd unit must NOT have `ExecStop=umount`** — it bricks agent restarts. If GFS2 is mounted and the unit has an ExecStop umount, systemd will try to unmount on restart, hang because the filesystem is busy, and the agent will never come back.
- **Agent restart requires a reboot if GFS2 is mounted** when ExecStop includes umount. Removing ExecStop fixes this — the agent can restart cleanly while GFS2 stays mounted.
- **Nodes with hung GFS2 need force-terminate, not graceful shutdown** — graceful shutdown tries to unmount, which hangs. Use `aws ec2 stop-instances --force` or `aws ec2 terminate-instances`.
