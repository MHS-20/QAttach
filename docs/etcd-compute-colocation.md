# etcd-Compute Colocation Plan

## Goal

Move the 3-node etcd cluster onto the compute instances so each compute node runs a
local etcd process. Eliminates dedicated etcd instances and the internal NLB.
Communication remains over the network (gRPC over node IPs, never localhost or Unix
sockets) to preserve the ability to split compute and etcd back onto separate hosts
later without code changes.

## Current Architecture

```
┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐
│    etcd Node 0     │  │    etcd Node 1     │  │    etcd Node 2     │
│  (dedicated EC2)   │  │  (dedicated EC2)   │  │  (dedicated EC2)   │
└────────┬───────────┘  └────────┬───────────┘  └────────┬───────────┘
         │ gRPC+mTLS             │                        │
         └───────────────────────┼────────────────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │ Internal NLB                          │
              └──────────────────┬───────────────────┘
                                 │
         ┌───────────────────────┼────────────────────────┐
         │                       │                        │
┌────────┴──────────┐  ┌────────┴──────────┐  ┌────────┴──────────┐
│   Compute Node 0  │  │   Compute Node 1  │  │   Compute Node 2  │
│  cluster-agent    │  │  cluster-agent    │  │  cluster-agent    │
│  lock_etcd.ko     │  │  lock_etcd.ko     │  │  lock_etcd.ko     │
│  GFS2 mount       │  │  GFS2 mount       │  │  GFS2 mount       │
└───────────────────┘  └───────────────────┘  └───────────────────┘
         │                       │                        │
         └───────────────────────┼────────────────────────┘
                    EBS io2 Multi-Attach
```

5 EC2 instances minimum: 3 etcd + 2 compute. The etcd fleet is fixed at 3; the
compute fleet scales independently.

## Proposed Architecture

```
┌────────────────────────────┐  ┌────────────────────────────┐  ┌────────────────────────────┐
│      Compute Node 0        │  │      Compute Node 1        │  │      Compute Node 2        │
│                            │  │                            │  │                            │
│  ┌──────────┐  ┌─────────┐ │  │  ┌──────────┐  ┌─────────┐ │  │  ┌──────────┐  ┌─────────┐ │
│  │  etcd    │◄─┤cluster- │ │  │  │  etcd    │◄─┤cluster- │ │  │  │  etcd    │◄─┤cluster- │ │
│  │  (local) │  │agent    │ │  │  │  (local) │  │agent    │ │  │  │  (local) │  │agent    │ │
│  └────┬─────┘  └────┬────┘ │  │  └────┬─────┘  └────┬────┘ │  │  └────┬─────┘  └────┬────┘ │
│       │              │     │  │       │              │     │  │       │              │     │
│       │         ┌────┴───┐ │  │       │         ┌────┴───┐ │  │       │         ┌────┴───┐ │
│       │         │lock_   │ │  │       │         │lock_   │ │  │       │         │lock_   │ │
│       │         │etcd.ko │ │  │       │         │etcd.ko │ │  │       │         │etcd.ko │ │
│       │         └────┬───┘ │  │       │         └────┬───┘ │  │       │         └────┬───┘ │
│       │              │     │  │       │              │     │  │       │              │     │
│       │         ┌────┴───┐ │  │       │         ┌────┴───┐ │  │       │         ┌────┴───┐ │
│       │         │  GFS2  │ │  │       │         │  GFS2  │ │  │       │         │  GFS2  │ │
│       │         └────┬───┘ │  │       │         └────┬───┘ │  │       │         └────┬───┘ │
└───────┼──────────────┼─────┘  └───────┼──────────────┼─────┘  └───────┼──────────────┼─────┘
        │              │                │              │                │              │
        │    ┌─────────┴────────────────┴──────────────┴────────────────┴─────┐        │
        │    │                    EBS io2 Multi-Attach                        │        │
        │    └────────────────────────────────────────────────────────────────┘        │
        │                                                                              │
        └──────────── gRPC+mTLS (peer + client, over node IPs, never localhost) ───────┘
```

3 EC2 instances minimum (or more). No dedicated etcd instances, no NLB.
Each compute node runs:
- `etcd` (systemd unit, managed by cluster-agent or a helper script)
- `cluster-agent`
- `lock_etcd.ko` + GFS2 mount

## Network Abstraction

**Critical requirement:** The cluster-agent still uses the compute node's private IP
as the etcd endpoint, not `localhost:2379`. The agent's `--etcd-endpoints` flag is
set to `https://<self-ip>:2379,https://<peer-ip>:2379,...`.

```
# On compute node 0 with IP 10.0.1.10:
cluster-agent --etcd-endpoints https://10.0.1.10:2379,https://10.0.1.20:2379,https://10.0.1.30:2379 ...
```

This means:
- The etcd client uses the same gRPC+mTLS path as it would with remote etcd.
- The round-trip stays within the kernel stack (packet never leaves the machine
  for the local endpoint), but the code path is identical.
- No code changes needed in `internal/etcd/`, `internal/lock/`, or `internal/fencing/`.
- To split etcd back onto dedicated hosts: change `--etcd-endpoints` to the new IPs.
  Literally a config change, zero code changes.

The etcd peer URLs (`--initial-advertise-peer-urls`, `--listen-peer-urls`) also use
the node's private IP on port 2380, same as today.

## Cluster-Agent Changes

### New responsibilities

1. **etcd lifecycle management**

   The agent must now start/stop the local etcd process. Two approaches:

   **Option A: systemd unit with agent as sidecar** (recommended)
   - `etcd.service` starts before `cluster-agent.service` (ordered via `Wants=`/`After=`)
   - Agent waits for local etcd to be healthy (with timeout), then connects
   - Agent handles membership: join/leave via `etcdctl member add/remove`
   - On shutdown: agent calls `etcdctl member remove <self>` before stopping etcd

   **Option B: agent spawns etcd as child process**
   - Agent starts etcd with `os/exec`, watches the process, handles signal propagation
   - More complex error handling; systemd already does this well

   Recommend Option A. The agent gains new CLI flags and a membership manager;
   systemd handles the process lifecycle.

2. **Bootstrap logic** (`internal/membership/` — new package)

   The first node to start must bootstrap the etcd cluster with
   `--initial-cluster-state new`. Subsequent nodes must use
   `--initial-cluster-state existing`.

   ```go
   type Membership struct {
       etcdCli   *etcd.Client
       nodeID    string
       nodeIP    string
       peerURL   string // https://<node-ip>:2380
       endpoints []string
   }

   // BootstrapOrJoin decides whether to bootstrap a new cluster or join an
   // existing one, then writes the appropriate etcd systemd drop-in.
   func (m *Membership) BootstrapOrJoin(ctx context.Context) error {
       // Check if any existing etcd member is reachable.
       for _, ep := range m.endpoints {
           if m.isEtcdHealthy(ctx, ep) {
               // An etcd cluster exists. Join as a new member.
               return m.joinExisting(ctx)
           }
       }
       // No reachable etcd. Bootstrap a new single-node cluster,
       // then later nodes will join us.
       return m.bootstrapNew(ctx)
   }
   ```

   **Bootstrap flow (first node):**
   ```
   1. Write /var/lib/etcd-bootstrap/etcd.conf with --initial-cluster-state new,
      --initial-cluster with only this node
   2. systemctl start etcd (single-node cluster)
   3. Wait for etcd health
   4. Write /cluster/members/<self> with session lease
   ```

   **Join flow (subsequent nodes):**
   ```
   1. Connect to existing etcd cluster
   2. etcdctl member add <new-name> --peer-urls=https://<new-ip>:2380
   3. Parse the output: get initial-cluster line with all members
   4. Write /var/lib/etcd-bootstrap/etcd.conf with --initial-cluster-state existing,
      --initial-cluster with all members (including self)
   5. systemctl start etcd
   6. Wait for etcd health
   7. Write /cluster/members/<self> with session lease
   ```

3. **New CLI flags:**

   ```
   --peer-url             string  "https://<self-ip>:2380"    etcd peer listen URL
   --etcd-data-dir        string  "/var/lib/etcd"             etcd data directory
   --etcd-name            string  "etcd-<instance-id-prefix>"  etcd node name
   --initial-cluster      string  ""                          etcd initial cluster string (bootstrap only)
   ```

4. **Clean shutdown path:**

   ```
   cluster-agent receives SIGTERM:
   1. Deregister node from /cluster/members/<self> (delete key, session lease expires)
   2. etcdctl member remove <self-name>
   3. systemctl stop etcd (or send SIGTERM if child process)
   4. Close etcd client
   5. Netlink server stop
   6. Exit 0
   ```

5. **Clean bootstrap path:**

   ```
   cluster-agent starts:
   1. Parse flags (same as today, plus new flags)
   2. Discover identity via IMDSv2
   3. BootstrapOrJoin: ensure local etcd is running and the node is a member
   4. Connect to etcd (using node IPs, not localhost)
   5. Create session lease
   6. Register node in /cluster/members/<self>
   7. ... rest is same as today
   ```

## etcd Membership Lifecycle

### Node Join

```
1. compute instance boots (ASG launch or manual)
2. systemd starts etcd.service (with --initial-cluster-state existing and an
   initial-cluster that includes all current members + self, configured by
   a pre-flight bootstrap script that ran "etcdctl member add")
3. systemd starts cluster-agent.service (After=etcd.service)
4. agent runs BootstrapOrJoin:
   a. Checks if etcd is already healthy locally
   b. If healthy: skip join (if running, we already joined)
   c. If not healthy: check existing cluster endpoints for membership
   d. If self is a member: restart etcd with existing membership
   e. If self is NOT a member: etcdctl member add, then start with existing state
5. agent creates session, registers in /cluster/members/<self>
6. agent handles mount request from kernel, claims journal slot
7. node is operational
```

### Node Leave (graceful)

```
1. ASG sends Terminating:Wait lifecycle hook
2. cluster-agent receives SIGTERM (or lifecycle hook triggers callback)
3. agent deregisters from /cluster/members/<self> (session lease expires)
4. agent calls etcdctl member remove <self-name>
5. etcd reconfigures: removes member from Raft consensus
6. agent stops etcd (systemctl stop etcd)
7. agent unregisters from kernel, stops netlink
8. ASG lifecycle hook completes → instance terminates
```

### Node Leave (crash/fence)

```
1. Other nodes detect lease expiry: /cluster/members/<failed> key deleted
2. Fencing CAS race: winner executes EC2 StopInstances
3. During fencing, winner ALSO calls etcdctl member remove <failed> (best-effort;
   if failed node is unreachable, etcd may take longer to reconfigure)
4. Epoch incremented
5. Journal recovery signaled to remaining nodes
6. Remaining etcd cluster reconfigures to remove failed member
```

### Member Removal and Quorum

**Constraint:** Removing a running etcd member from an N-node cluster reduces the
quorum floor from `floor(N/2)+1` to `floor((N-1)/2)+1`. If this drops the number
of healthy members below the new quorum, the cluster becomes unavailable.

| Cluster size | Before removal | After removal | Max removable |
|-------------|---------------|--------------|---------------|
| 3 | quorum=2 | quorum=2 | 1 (if 3rd is still up) |
| 4 | quorum=3 | quorum=2 | 1 |
| 5 | quorum=3 | quorum=3 | 1 (still quorum of 3, but now only 3 members, all must be up) |

**Rule:** Never remove more than 1 member at a time. When scaling down, remove one,
wait for etcd to stabilize, then remove the next.

**Fencing caveat:** If you have exactly 3 nodes and 1 crashes, the remaining 2
still have quorum (2/3). You can remove the failed member. But if a second node
crashes before the removal completes, quorum is lost and etcd freezes. There is no
workaround — this is a fundamental Raft property. Mitigations:
- Run 5 nodes for production (tolerates 2 failures)
- Accept that 3 nodes = 1 failure tolerance (same as today with dedicated etcd)
- The colocation doesn't change the quorum math; it just increases the blast radius
  when a compute node fails (lose both compute AND etcd member)

## epoch Counter Integration

The `cluster/epoch` key (already implemented in `internal/fencing/fencer.go:142`)
becomes critical when etcd is colocated. The epoch is incremented on every fence
event and validated on mount/lock operations.

**Recovery after full cluster restart:**
1. All 3 nodes power off (data center outage, full ASG scale-in, etc.)
2. etcd data is cold on each node's `/var/lib/etcd`
3. When nodes restart: etcd starts, replays WAL, forms Raft group
4. cluster-agent connects, sees epoch unchanged from before crash
5. No journal replay needed — journals were cleanly unmounted before shutdown
   (if the shutdown was clean), or journals exist on disk and GFS2 handles them

**Recovery after partial crash + fence:**
1. Node B crashes, node A fences it (epoch incremented to N+1)
2. Node B restarts, etcd restarts, replays WAL
3. Node B's agent connects to etcd, sees epoch N+1 (which is > its last known epoch)
4. Agent knows it was fenced → refuses to re-mount GFS2
5. Operator (or automation) must clear the node's state before rejoining

The epoch is compared at mount time: the kernel stores the epoch revision during
mount, and the agent validates it against `cluster/epoch` on every lock grant.
If the epoch has advanced beyond what the kernel knows, the agent denies the lock
(deny reason: stale epoch = fenced).

## Infrastructure Changes

### Removed:
- Dedicated etcd EC2 instances (3 × m5.large or similar)
- Internal NLB for etcd
- `scripts/infra/setup-etcd.sh` (merged into setup-compute.sh)
- `state_get etcd_ips` / `state_get etcd_public_ips` from state.sh

### Added/changed:
- `setup-compute.sh` now installs etcd binary and configures `etcd.service` on
  each compute node
- `create-infra.sh` produces fewer instances (3-5 compute + 0 etcd)
- TLS certs generated during compute setup (but still use compute IPs for SANs)
- Infra state file stores `etcd_endpoints` as the compute IPs on port 2379

### Minimum instance count:
3 compute nodes (to form etcd quorum). Could add more compute nodes to the etcd
cluster, but 3-5 is the practical range for etcd. Nodes beyond the etcd members
would need to talk to etcd on other compute nodes — this is indistinguishable
from the current architecture.

## Failure Modes

| Failure | Impact | Handling |
|---------|--------|----------|
| 1 compute node down, 2 remain | etcd quorum maintained (2/3), GFS2 functional on 2 nodes | Fence the failed node, remove it from etcd membership |
| 2 compute nodes down, 1 remains | etcd loses quorum (1/3), GFS2 stalls (lock requests hang) | Unrecoverable until a second node returns. The single remaining node's agent cannot write to etcd. |
| All 3 nodes down | etcd cold. On restart, Raft replays WAL and restores state. | If clean shutdown: no journal recovery. If crash: GFS2 per-node journal replay. |
| etcd data corruption on one node | Raft heals: the corrupt node either catches up from peers or is removed | Remove corrupt node from membership, destroy its data dir, re-add as new member |
| Agent crashes, etcd stays up | etcd still has quorum. Session lease expires, member key deleted, other nodes fence. | Agent restarts, creates new session, re-registers. etcd is unaffected. |
| etcd crashes, agent stays up | Local agent can't reach etcd even though it's local — same as remote etcd failure. | Agent health check fails locally, alert fires. etcd restarts and replays WAL. |

## Operational Impact

### Pros
- **Fewer instances**: 3 vs 5 minimum (40% cost reduction on EC2)
- **No NLB**: eliminates a network hop and failure point
- **Simpler infra scripts**: fewer instance types to manage
- **Faster boot**: etcd starts in parallel with kernel module load
- **Always correct**: no chance of etcd endpoint mismatch (the node IS the etcd)

### Cons
- **Blast radius**: a compute failure also loses an etcd member
- **etcd disk I/O competes with GFS2 I/O** on the same instance (EBS bandwidth
  is shared; etcd WAL writes are small but frequent — configurable via rate limits)
- **Membership tied to compute**: adding/removing compute nodes requires etcd
  membership changes, which are not free (Raft reconfiguration takes ~1s)
- **Debugging complexity**: etcd logs on the same host as GFS2 kernel messages

### Mitigations
- Use dedicated EBS volumes for etcd data (`/var/lib/etcd` on a separate gp3 volume
  or the root volume; etcd WAL is write-heavy, root EBS is fine)
- Rate-limit etcd WAL snapshot frequency (`--snapshot-count=100000`)
- Run at least 3 compute nodes (minimum etcd quorum)
- For production: run 5 compute nodes (tolerates 2 etcd failures, 3 GFS2 nodes)
- Keep etcd on the root volume (no separate EBS) to avoid detach-on-fence issues

## Implementation Phases

### Phase 1: Agent bootstrap logic (no etcd process management yet)
1. Add `internal/membership/` package with `BootstrapOrJoin`
2. Add new CLI flags (`--peer-url`, `--etcd-data-dir`, `--etcd-name`)
3. Make `--etcd-endpoints` default to nothing (must be explicit)
4. Add `--bootstrap` flag: when true, agent runs bootstrap logic; when false,
   behaves as today (assumes etcd is already running)
5. Unit tests for bootstrap decisions

### Phase 2: systemd unit and setup script
1. Create `etcd.service` systemd unit template
2. Create `cluster-agent.service` with `After=etcd.service`
3. Update `setup-compute.sh` to install etcd binary, generate certs, configure units
4. Generate TLS certs with compute IPs as SANs (same as today but for compute IPs)
5. Test on clean infra: bootstrap first node, add second and third

### Phase 3: Clean shutdown/startup
1. Implement graceful member removal in agent shutdown path
2. Handle `etcdctl member remove` before `systemctl stop etcd`
3. Test: start 3 nodes, stop one gracefully → verify remaining 2 still work
4. Test: start 3 nodes, kill one (crash) → verify fencing + member removal
5. Test: full cluster restart → verify etcd data survives, GFS2 remounts

### Phase 4: Remove dedicated infra scripts
1. Remove `scripts/infra/setup-etcd.sh`
2. Remove etcd instance creation from `create-infra.sh`
3. Update `destroy-infra.sh`
4. Update all docs

## Constraints & Non-Goals

- **DO NOT** use `localhost:2379` as an etcd endpoint. Always use the node IP.
- **DO NOT** use Unix domain sockets for etcd communication.
- **DO NOT** embed etcd as a library (etcd is not designed for embedding).
- **DO NOT** assume etcd data survives instance termination (use EBS root volume).
- **DO NOT** change the etcd key schema or glock protocol.
- **DO NOT** change the Netlink protocol between kernel and agent.
- The number of etcd members can exceed 3 but should stay odd and ≤7 for
  performance. Each additional member adds write latency (Raft commit to majority).
- If the compute fleet exceeds the etcd member count, non-etcd-member compute nodes
  connect to the etcd members via the same gRPC+mTLS path — identical to today.
