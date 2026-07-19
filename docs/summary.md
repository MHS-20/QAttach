# QAttach — System Overview & Current Status

## What It Is

QAttach replaces the standard DLM stack with an etcd-backed lock manager for
GFS2 on EBS Multi-Attach. Three EC2 compute nodes share an EBS io2 volume. A
custom kernel module (`lock_etcd`, built into `gfs2.ko`) speaks Netlink to a Go
daemon (`cluster-agent`) on each node, which uses colocated etcd (3-node Raft)
for lock state.

## What Works

- Custom kernel build pipeline (launch.sh) — `--no-hostonly` dracut, depmod, latest gfs2-utils
- Infrastructure provisioning (create/destroy)
- Agent build + deployment (setup-compute.sh)
- etcd colocation on compute nodes (3-node cluster)
- GFS2 format + mount on all 3 nodes
- Single-node I/O (read, write, create, append)
- Multi-node mount (MOUNT lock release fixed)
- Heartbeat lock handoff (BAST→UNLOCK→GRANT on all 3 nodes, 30s cycle)
- FIFO lock handoff (ProcessLock respects /next marker)
- Agent-side lock operations (ProcessLock + retryProcessLock)
- Kernel BAST mechanism (glock stays in bast list across UNLOCK→ACQUIRE cycles)

## Current State

| Capability | Status |
|---|---|
| Custom kernel build pipeline | Stable |
| Infrastructure provisioning | Stable |
| Agent build + deployment | Stable |
| etcd colocation on compute nodes | Stable |
| GFS2 format + mount on all nodes | Stable |
| Single-node I/O | Stable |
| Cross-node sequential I/O | **Working** (write on node0, read on node1+2 confirmed) |
| Cross-node concurrent I/O | **Working at low throughput** (1op/5s, 3 shared files, 94-100% success) |
| Fencing via EC2 API | Implemented (IAM role required) |

## Throughput Ceiling

Concurrent I/O at higher rates (10 ops/s, 3 nodes) can deadlock due to etcd
consensus latency (~5ms per write) vs DLM's microsecond in-kernel lock cycles.
GFS2's `run_queue` and glock work scheduling can't complete pending demotions
before the next request arrives, causing D-state hangs. This is a fundamental
etcd-vs-DLM performance gap, not a correctness bug.

## Next Steps

1. Replace polling with etcd Watch in retryProcessLock
2. In-kernel lock locality fast-path for already-held locks
3. Investigate LM_FLAG_TRY behavior on Amazon Linux 2023's GFS2 build
