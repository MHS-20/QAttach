# Plan 2

# Implementation Plan: etcd-backed DLM Replacement for GFS2 on Multi-Attach EBS

## Architecture Summary

Replace corosync/pacemaker/lock_dlm with:

- **etcd** (fixed 3-node Raft cluster) as the single source of truth for membership, glocks, and fencing coordination
- **`cluster-agent`** (Go userspace daemon, one per compute node) owning all etcd communication, fencing logic, and EC2 API calls
- **`lock_etcd`** (custom kernel module) implementing GFS2's `lm_lockops` interface, replacing `lock_dlm`; communicates with `cluster-agent` exclusively via Netlink
- **GFS2** kernel filesystem, unchanged on-disk format; journals managed entirely on-disk by GFS2 itself
- **EBS io2 Multi-Attach** raw block device, one volume per AZ, attached to all compute nodes in that AZ

### Resolved design decisions

| Decision | Resolution |
| --- | --- |
| Fencing mechanism | EC2 API (`StopInstances` / `DetachVolume`) called by `cluster-agent` on the surviving node that wins the fencing CAS race |
| Fencing detection | Pure etcd Watch — no node-to-node monitoring mesh; session lease expiry is the sole liveness signal |
| Fencing tokens | etcd revision of the lock key, passed with every grant, stored in kernel module, validated on stale-wake |
| kernel↔agent channel | Netlink socket (AF_NETLINK custom family); no Unix sockets from kernel space |
| etcd access | Direct gRPC from each `cluster-agent` to etcd NLB endpoint; no proxy tier |
| Journal management | Removed from etcd entirely; GFS2 manages journals as on-disk files; only the journal *slot claim* glock goes through `lock_etcd` |
| Session vs. lock leases | One session lease per node (keepalive unconditionally); individual glock keys attached to session lease (auto-deleted on crash) |
| Idle nodes | Never fenced; session lease renewal is unconditional and independent of I/O |

---

## etcd Key Schema (final)

```
/cluster/members/{node_id}      → {instance_id, ip, az, heartbeat_ts}   ← attached to session lease
/cluster/fencing/{node_id}      → {fencer_node_id}                       ← short TTL, CAS race winner
/cluster/epoch                  → uint64                                  ← increments on crash only
/locks/glock/{type}/{number}    → {owner_node_id, mode: EX|PR|CW}        ← attached to session lease
```

**What was removed vs. v1:**

- `/fs/journal_head` — not needed, GFS2 manages this on-disk
- `/fs/journals/{node_id}` — not needed, GFS2 assigns journal slots via glock
- `expires_at` field on lock keys — not needed; expiry is governed by session lease TTL, not a separate clock

---

## IAM Role for `cluster-agent`

Every compute node running `cluster-agent` must have an IAM instance role with the following permissions. Attach this role at ASG launch template level so no credentials need to be managed manually.

### IAM policy (minimum required)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FencingStopInstance",
      "Effect": "Allow",
      "Action": [
        "ec2:StopInstances"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/ClusterName": "${aws:RequestTag/ClusterName}"
        }
      }
    },
    {
      "Sid": "FencingDetachVolume",
      "Effect": "Allow",
      "Action": [
        "ec2:DetachVolume"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:instance/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/ClusterName": "${aws:RequestTag/ClusterName}"
        }
      }
    },
    {
      "Sid": "DescribeForFencingConfirmation",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LifecycleHookCompletion",
      "Effect": "Allow",
      "Action": [
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:RecordLifecycleActionHeartbeat"
      ],
      "Resource": "arn:aws:autoscaling:*:*:autoScalingGroup:*:autoScalingGroupName/*"
    },
    {
      "Sid": "SelfIdentification",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstanceAttribute"
      ],
      "Resource": "*"
    }
  ]
}
```

### Notes on the policy

- The `Condition` block on `StopInstances` and `DetachVolume` scopes the permission to instances and volumes tagged with the same `ClusterName`. Tag all ASG instances and the EBS volume at creation time. This prevents a bug or compromise in one cluster from fencing nodes in another.
- `DescribeInstances` and `DescribeVolumes` are needed to poll for fencing confirmation (wait until instance state is `stopped` or volume attachment state is `detached`) before signaling the kernel module.
- `SelfIdentification` allows the agent to read its own instance ID from the EC2 metadata service on startup (alternatively use IMDSv2 HTTP directly without any IAM permission).
- Do **not** grant `ec2:TerminateInstances` — stopping is sufficient for fencing and is reversible.

### IMDSv2 self-identification at bootstrap

`cluster-agent` must determine its own instance ID at startup to populate `/cluster/members/{node_id}`. Use IMDSv2 (token-based metadata):

```go
// Step 1: get token
tokenResp, _ := http.Post(
    "http://169.254.169.254/latest/api/token", "",
    strings.NewReader(""),
)
// Add header: X-aws-ec2-metadata-token-ttl-seconds: 21600
token := readBody(tokenResp)

// Step 2: get instance ID
req, _ := http.NewRequest("GET",
    "http://169.254.169.254/latest/meta-data/instance-id", nil)
req.Header.Set("X-aws-ec2-metadata-token", token)
instanceID := readBody(http.DefaultClient.Do(req))
```

**Reference:** [EC2 IMDSv2 docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

---

## Phase 0: Infrastructure Setup

**Goal:** Provision the base infrastructure before writing any code.

### 0.1 — etcd cluster

Deploy a **3-node** etcd cluster on dedicated EC2 instances separate from the compute fleet. Use `t3.medium` minimum (etcd is I/O sensitive — SSD-backed instances only).

Expose via an **internal Network Load Balancer** (NLB) or a Route53 private CNAME pointing at all three etcd IPs. The endpoint is baked into `cluster-agent` config at deployment time.

Secure with mutual TLS: generate a CA, issue server certs for each etcd node, and issue a client cert for `cluster-agent`. Store the client cert+key in AWS Secrets Manager or as EC2 Parameter Store SecureString; `cluster-agent` fetches it on startup.

```bash
# Example etcd startup flags (per node)
etcd \
  --name etcd-1 \
  --data-dir /var/lib/etcd \
  --listen-client-urls https://0.0.0.0:2379 \
  --advertise-client-urls https://10.0.0.10:2379 \
  --listen-peer-urls https://0.0.0.0:2380 \
  --initial-advertise-peer-urls https://10.0.0.10:2380 \
  --initial-cluster "etcd-1=https://10.0.0.10:2380,etcd-2=https://10.0.0.11:2380,etcd-3=https://10.0.0.12:2380" \
  --client-cert-auth --trusted-ca-file=/etc/etcd/ca.crt \
  --cert-file=/etc/etcd/server.crt --key-file=/etc/etcd/server.key \
  --peer-client-cert-auth --peer-trusted-ca-file=/etc/etcd/ca.crt \
  --peer-cert-file=/etc/etcd/peer.crt --peer-key-file=/etc/etcd/peer.key
```

**Reference:** [etcd installation](https://etcd.io/docs/v3.5/install/), [etcd security](https://etcd.io/docs/v3.5/op-guide/security/)

### 0.2 — EBS volume

```bash
aws ec2 create-volume \
  --volume-type io2 \
  --size 30 \
  --iops 100 \
  --multi-attach-enabled \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=ClusterName,Value=mycluster}]'
```

Attach to all compute nodes in the same AZ. Multi-Attach is AZ-scoped — all nodes must be in the same AZ as the volume.

**Reference:** [EBS Multi-Attach docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html)

### 0.3 — Compute node prerequisites

On every compute node AMI (bake into the AMI or install via user-data):

```bash
# GFS2 userspace tools
apt-get install -y gfs2-utils

# Kernel headers for module build
apt-get install -y linux-headers-$(uname -r) build-essential dkms

# AWS CLI v2 (for fencing confirmation polling)
# installed via official installer

# Verify Multi-Attach device is visible
lsblk  # should show /dev/nvme1n1 or similar
```

---

## Phase 1: `cluster-agent` (Userspace Daemon)

**Goal:** Build the Go daemon that owns all etcd interactions, the Netlink server, and the fencing logic.

### 1.1 — Session lifecycle

At startup, `cluster-agent`:

1. Reads its instance ID from IMDSv2.
2. Connects to etcd with mTLS.
3. Creates a **session lease** with TTL=15s and starts `KeepAlive` (renewed every 5s, unconditionally — idle nodes are never fenced).
4. Atomically writes `/cluster/members/{node_id}` attached to the session lease:

```go
import (
    clientv3 "go.etcd.io/etcd/client/v3"
    "go.etcd.io/etcd/client/v3/concurrency"
)

sess, err := concurrency.NewSession(client,
    concurrency.WithTTL(15))  // session lease, auto-renewed

memberVal := fmt.Sprintf(`{"instance_id":"%s","ip":"%s","az":"%s"}`,
    instanceID, localIP, az)

_, err = client.Put(ctx, "/cluster/members/"+nodeID, memberVal,
    clientv3.WithLease(sess.Lease()))
```

1. Opens the Netlink socket and starts listening for glock requests from the kernel module (see Phase 2).
2. Starts a Watch on `/cluster/members/` to detect peer failures (see Phase 3 — Fencing).

### 1.2 — Glock request handling (Netlink → etcd → Netlink)

When the kernel module sends a `LETCD_MSG_LOCK_REQ` via Netlink:

```go
func handleLockRequest(req LockRequest) {
    key := fmt.Sprintf("/locks/glock/%d/%d", req.GlockType, req.GlockNumber)

    // CAS: acquire only if key does not exist or is held by us already
    txnResp, err := client.Txn(ctx).
        If(clientv3.Compare(clientv3.Version(key), "=", 0)).
        Then(clientv3.OpPut(key, lockValue,
            clientv3.WithLease(sess.Lease()))). // attached to session lease
        Else(clientv3.OpGet(key)).
        Commit()

    if txnResp.Succeeded {
        // Granted — send revision as fencing token
        sendNetlink(LETCD_MSG_LOCK_GRANT, LockGrant{
            RequestID: req.RequestID,
            Mode:      req.RequestedMode,
            Revision:  txnResp.Header.Revision,
        })
    } else {
        // Contended — watch for release, then retry
        watchAndRetry(key, req)
    }
}
```

For **shared (PR) glocks** on the same key, multiple holders are allowed. The etcd value stores a list of holders; the CAS condition checks for absence of any EX holder.

### 1.3 — BAST (blocking AST) delivery

When a new EX request arrives for a key currently held in SH or EX by another node, the agent must demote the current holder. The Watch on `/locks/glock/` fires when another agent puts a "demote request" sentinel key. On receipt:

```go
// Agent receives: another node wants EX on a key we hold SH
// Send BAST to kernel module
sendNetlink(LETCD_MSG_BAST, BastNotification{
    GlockType:   glockType,
    GlockNumber: glockNumber,
    TargetMode:  LM_ST_UNLOCKED,
})
// Kernel module calls gfs2_glock_cb() → GFS2 invalidates cache and demotes
```

### 1.4 — Clean shutdown

On `SIGTERM` (from systemd `ExecStop`):

1. Signal GFS2 to unmount (`umount /mnt/shared`) — this flushes all dirty pages, releases all glocks.
2. GFS2 unmount triggers `lm_unmount()` in the kernel module, which sends `LETCD_MSG_UNMOUNT` to the agent.
3. Agent deletes `/cluster/members/{node_id}` explicitly (rather than waiting for TTL), and revokes the session lease — this atomically deletes all attached lock keys.
4. Agent signals the ASG lifecycle hook completion via EC2 API.

**References:**

- [etcd Go client v3](https://pkg.go.dev/go.etcd.io/etcd/client/v3)
- [etcd concurrency (sessions)](https://pkg.go.dev/go.etcd.io/etcd/client/v3/concurrency)
- [etcd Txn / CAS API](https://etcd.io/docs/v3.5/learning/api/)
- [etcd API guarantees](https://etcd.io/docs/v3.5/learning/api_guarantees/)

---

## Phase 2: `lock_etcd` Kernel Module

**Goal:** Implement GFS2's `lm_lockops` interface, replacing `lock_dlm`. Communicate with `cluster-agent` via Netlink.

### Key source files to read before writing any code

These must be read in this order:

1. [`fs/gfs2/lm_interface.h`](https://elixir.bootlin.com/linux/latest/source/fs/gfs2/lm_interface.h) — defines `struct lm_lockops` and every callback signature you must implement
2. [`fs/gfs2/lock_dlm.c`](https://elixir.bootlin.com/linux/latest/source/fs/gfs2/lock_dlm.c) — your primary template; implement the same interface, swap dlm calls for Netlink calls to `cluster-agent`
3. [`fs/gfs2/glock.c`](https://elixir.bootlin.com/linux/latest/source/fs/gfs2/glock.c) — understand `gfs2_glock_complete()`, `gfs2_glock_cb()`, and `run_queue()`
4. [`fs/gfs2/incore.h`](https://elixir.bootlin.com/linux/latest/source/fs/gfs2/incore.h) — `struct gfs2_glock`, `struct lm_lockstruct`, `struct gfs2_sbd`
5. [GFS2 glock internals doc](https://docs.kernel.org/filesystems/gfs2-glocks.html) — glock state machine, mode transitions, BAST/AST model
6. [GFS2 uevents doc](https://docs.kernel.org/5.19/filesystems/gfs2-uevents.html) — how journal recovery events are reported

### 2.1 — `lm_lockops` registration

```c
static const struct lm_lockops lock_etcd_ops = {
    .lm_proto_name      = "lock_etcd",
    .lm_mount           = lock_etcd_mount,
    .lm_first_done      = lock_etcd_first_done,
    .lm_recovery_result = lock_etcd_recovery_result,
    .lm_unmount         = lock_etcd_unmount,
    .lm_lock            = lock_etcd_lock,
    .lm_cancel          = lock_etcd_cancel,
    .lm_put_lock        = lock_etcd_put_lock,
};

static int __init lock_etcd_init(void)
{
    return gfs2_register_lockproto(&lock_etcd_ops);
}

static void __exit lock_etcd_exit(void)
{
    gfs2_unregister_lockproto(&lock_etcd_ops);
}
```

### 2.2 — Netlink protocol definition

Define a custom Netlink family. All messages between kernel module and `cluster-agent` use this family. The kernel side creates the Netlink socket; `cluster-agent` connects to it as a userspace client.

```c
/* In a shared header included by both the kernel module and cluster-agent */
#define LETCD_NETLINK_FAMILY  31       /* pick an unused number */
#define LETCD_MAX_PAYLOAD     256

/* Message types */
#define LETCD_MSG_LOCK_REQ    1   /* kernel → agent: request glock */
#define LETCD_MSG_LOCK_GRANT  2   /* agent → kernel: granted + fencing token */
#define LETCD_MSG_LOCK_DENY   3   /* agent → kernel: denied (contended) */
#define LETCD_MSG_LOCK_WAIT   4   /* agent → kernel: queued, will notify on release */
#define LETCD_MSG_BAST        5   /* agent → kernel: demote callback */
#define LETCD_MSG_LOCK_REL    6   /* kernel → agent: release glock */
#define LETCD_MSG_RECOVERY_OK 7   /* agent → kernel: node fenced, journal replay safe */
#define LETCD_MSG_UNMOUNT     8   /* kernel → agent: filesystem unmounting */

struct letcd_lock_req {
    __u64 request_id;       /* monotonic, for async correlation */
    __u64 glock_number;
    __u32 glock_type;
    __u32 requested_mode;   /* LM_ST_EXCLUSIVE=1, LM_ST_SHARED=3, LM_ST_DEFERRED=5 */
};

struct letcd_lock_grant {
    __u64 request_id;
    __u32 granted_mode;
    __u64 etcd_revision;    /* fencing token — store this in the glock */
};

struct letcd_bast {
    __u64 glock_number;
    __u32 glock_type;
    __u32 target_mode;      /* mode to demote to */
};

struct letcd_recovery_ok {
    __u32 jid;              /* journal ID of the recovered node */
};
```

**Kernel-side Netlink setup:**

```c
static struct sock *letcd_nlsk;

static void letcd_nl_recv(struct sk_buff *skb)
{
    struct nlmsghdr *nlh = nlmsg_hdr(skb);
    void *payload = nlmsg_data(nlh);

    switch (nlh->nlmsg_type) {
    case LETCD_MSG_LOCK_GRANT:
        letcd_handle_grant(payload);
        break;
    case LETCD_MSG_LOCK_DENY:
        letcd_handle_deny(payload);
        break;
    case LETCD_MSG_BAST:
        letcd_handle_bast(payload);
        break;
    case LETCD_MSG_RECOVERY_OK:
        letcd_handle_recovery(payload);
        break;
    }
}

static int __init letcd_netlink_init(void)
{
    struct netlink_kernel_cfg cfg = { .input = letcd_nl_recv };
    letcd_nlsk = netlink_kernel_create(&init_net, LETCD_NETLINK_FAMILY, &cfg);
    return letcd_nlsk ? 0 : -ENOMEM;
}
```

**References:** [Netlink tutorial (Linux Journal)](https://www.linuxjournal.com/article/7356), [Kernel Connector docs](https://www.kernel.org/doc/html/latest/driver-api/connector.html)

### 2.3 — `lock_etcd_lock()` — the core glock path

```c
static void lock_etcd_lock(struct gfs2_glock *gl)
{
    struct letcd_lock_req req = {
        .request_id    = atomic64_inc_return(&letcd_req_counter),
        .glock_number  = gl->gl_name.ln_number,
        .glock_type    = gl->gl_name.ln_type,
        .requested_mode = gl->gl_target,
    };

    /* Register pending request so the recv callback can find it */
    letcd_pending_insert(req.request_id, gl);

    /* Send to cluster-agent asynchronously */
    letcd_nl_send(LETCD_MSG_LOCK_REQ, &req, sizeof(req));

    /* Return immediately — GFS2 glock state machine will wait */
    /* When agent replies, letcd_handle_grant() calls gfs2_glock_complete() */
}

static void letcd_handle_grant(struct letcd_lock_grant *grant)
{
    struct gfs2_glock *gl = letcd_pending_pop(grant->request_id);
    if (!gl) return;

    /* Store fencing token in glock private data */
    letcd_gl_data(gl)->etcd_revision = grant->etcd_revision;

    /* Unblock GFS2 glock state machine */
    gfs2_glock_complete(gl, 0);
}
```

### 2.4 — Fencing token stale-wake guard

When a node wakes up from a hypervisor pause with a stale glock (its revision is lower than the current etcd revision), the agent will detect this on the next lock operation and deny it. The kernel module must handle the denial:

```c
static void letcd_handle_deny(struct letcd_lock_deny *deny)
{
    struct gfs2_glock *gl = letcd_pending_pop(deny->request_id);
    if (!gl) return;

    /* Revision mismatch — our cached state is stale */
    /* Tell GFS2 to invalidate caches and retry acquisition */
    gfs2_glock_complete(gl, -ESTALE);
}
```

On the agent side, before granting, compare the incoming request's stored revision (if any) against the current etcd revision for that key. If the node has a stale revision, deny and force a re-acquire from a clean state.

### 2.5 — BAST handling (blocking AST)

```c
static void letcd_handle_bast(struct letcd_bast *bast)
{
    struct gfs2_glock *gl = letcd_find_glock(bast->glock_type,
                                              bast->glock_number);
    if (!gl) return;

    /* Tell GFS2 to demote/invalidate — it will call back into lm_lock()
       with the new (lower) target mode when ready */
    gfs2_glock_cb(gl, bast->target_mode);
}
```

### 2.6 — Journal slot claim (mount path)

In `lock_etcd_mount()`, GFS2 needs a journal ID (`jid`) assigned. The module requests a journal glock (type `LM_TYPE_JOURNAL`) in EX mode. The agent acquires it in etcd. GFS2's own journal assignment logic then maps the glock to a journal slot. This is the only journal-related thing that touches etcd — the journal content itself is entirely on-disk.

```c
static int lock_etcd_mount(struct gfs2_sbd *sdp, const char *table)
{
    /* Send mount request to agent; agent registers membership in etcd */
    /* Agent replies with assigned jid */
    int jid = letcd_request_mount(sdp);
    if (jid < 0) return jid;

    sdp->sd_lockstruct.ls_jid = jid;
    /* Clear SDF_NOJOURNALID so GFS2 proceeds with mount */
    clear_bit(SDF_NOJOURNALID, &sdp->sd_flags);
    smp_mb__after_atomic();
    wake_up_bit(&sdp->sd_flags, SDF_NOJOURNALID);
    return 0;
}
```

### 2.7 — Glock mode mapping

| GFS2 requested mode | etcd lock mode | Notes |
| --- | --- | --- |
| `LM_ST_EXCLUSIVE` | `EX` | One holder, exclusive write |
| `LM_ST_SHARED` | `PR` (protected read) | Multiple concurrent SH holders allowed |
| `LM_ST_DEFERRED` | `CW` (concurrent write) | Direct I/O; incompatible with SH, compatible with other CW |
| `LM_ST_UNLOCKED` | (release) | Delete key from etcd |

**Reference:** [GFS2 glock internals](https://docs.kernel.org/filesystems/gfs2-glocks.html)

---

## Phase 3: Fencing via etcd Watch + EC2 API

**Goal:** Detect node failures exclusively through etcd and execute EC2 fencing without any node-to-node communication.

### 3.1 — Failure detection

Each `cluster-agent` runs a Watch on all member keys:

```go
watchCh := client.Watch(ctx,
    "/cluster/members/",
    clientv3.WithPrefix(),
    clientv3.WithPrevKV())   // critical: get last known value before deletion

for resp := range watchCh {
    for _, ev := range resp.Events {
        if ev.Type == clientv3.EventTypeDelete {
            // A node's session lease expired
            failedNodeID  := strings.TrimPrefix(string(ev.Kv.Key), "/cluster/members/")
            lastKnownVal  := ev.PrevKv.Value  // contains instance_id even after key gone
            go handlePeerFailure(failedNodeID, lastKnownVal)
        }
    }
}
```

The `PrevKv` field is essential — it gives you the instance ID of the failed node from the last written value, even though the key no longer exists in etcd.

### 3.2 — Fencing race (CAS — one winner)

Multiple surviving nodes will all see the same DELETE event. Only one should execute the fence. Use a CAS write to a fencing key:

```go
func handlePeerFailure(failedNodeID string, lastVal []byte) {
    fencingKey := "/cluster/fencing/" + failedNodeID

    // Race to become the fencing coordinator
    txnResp, _ := client.Txn(ctx).
        If(clientv3.Compare(clientv3.Version(fencingKey), "=", 0)).
        Then(clientv3.OpPut(fencingKey, localNodeID,
            clientv3.WithLease(shortLease))). // TTL ~60s, in case fencer crashes mid-way
        Commit()

    if !txnResp.Succeeded {
        // Another node won the race; do nothing
        return
    }

    // We are the fencing coordinator
    var info MemberInfo
    json.Unmarshal(lastVal, &info)
    executeFencing(info.InstanceID, failedNodeID)
}
```

### 3.3 — EC2 fencing execution

```go
func executeFencing(instanceID, failedNodeID string) {
    ec2Client := ec2.NewFromConfig(awsCfg)

    // Step 1: Force-stop the instance (prevents any future writes)
    ec2Client.StopInstances(ctx, &ec2.StopInstancesInput{
        InstanceIds: []string{instanceID},
        Force:       aws.Bool(true),
    })

    // Step 2: Poll until instance is stopped (max ~60s)
    waiter := ec2.NewInstanceStoppedWaiter(ec2Client)
    err := waiter.Wait(ctx,
        &ec2.DescribeInstancesInput{InstanceIds: []string{instanceID}},
        60*time.Second)

    if err != nil {
        // Fallback: force-detach the EBS volume from this instance
        ec2Client.DetachVolume(ctx, &ec2.DetachVolumeInput{
            VolumeId:   aws.String(ebsVolumeID),
            InstanceId: aws.String(instanceID),
            Force:      aws.Bool(true),
        })
        // Poll until detached
        waitForVolumeDetached(instanceID)
    }

    // Step 3: Increment cluster epoch (marks a crash event)
    incrementEpoch()

    // Step 4: Signal kernel module — journal recovery is now safe
    sendNetlink(LETCD_MSG_RECOVERY_OK, RecoveryOk{JID: resolveJID(failedNodeID)})

    // Step 5: Write fencing result so other nodes know it's done
    client.Put(ctx, "/cluster/fencing/"+failedNodeID, "done")
}
```

**Fencing latency budget:**

| Step | Typical duration |
| --- | --- |
| etcd Watch delivery after lease expiry | <100ms |
| CAS race + win | <50ms |
| EC2 StopInstances API call | 1–3s |
| Instance reaches `stopped` state | 15–45s |
| Netlink signal to kernel module | <1ms |

Total: ~20–50s from crash to journal recovery start. This is the window during which GFS2 I/O is frozen on surviving nodes. It is comparable to traditional fencing with IPMI/STONITH.

**References:**

- [AWS SDK Go v2 — EC2 StopInstances](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#Client.StopInstances)
- [AWS SDK Go v2 — EC2 DetachVolume](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#Client.DetachVolume)
- [AWS SDK Go v2 — InstanceStoppedWaiter](https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#InstanceStoppedWaiter)
- [EC2 IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

---

## Phase 4: GFS2 Filesystem Provisioning

**Goal:** Format and mount GFS2 using `lock_etcd`.

### 4.1 — Format (run once, on one node only)

```bash
# Load the module first (must be installed on this node)
modprobe lock_etcd etcd_endpoints="https://etcd-nlb.internal:2379" \
                   etcd_cert=/etc/cluster-agent/client.crt \
                   etcd_key=/etc/cluster-agent/client.key \
                   etcd_ca=/etc/cluster-agent/ca.crt

# Pre-provision journals generously: max expected simultaneous nodes + buffer
# Journals are free to add later with gfs2_jadd (no unmount needed)
mkfs.gfs2 \
  -p lock_etcd \
  -t mycluster:sharedfs \
  -j 16 \
  /dev/nvme1n1
```

Note: `lock_etcd` must match `lm_proto_name` exactly in the kernel module. The `-t clustername:fsname` value is written to the superblock and used as the DLM lock table namespace.

### 4.2 — Mount on each compute node

```bash
mount -t gfs2 \
  -o lockproto=lock_etcd,locktable=mycluster:sharedfs,noatime \
  /dev/nvme1n1 /mnt/shared
```

`cluster-agent` must be running and connected to etcd before `mount` is called. The `lock_etcd_mount()` callback will block until the agent responds with a journal ID.

### 4.3 — Adding journals dynamically

When scaling the cluster beyond the initial journal count:

```bash
# Run on any node with the filesystem mounted — no unmount needed
gfs2_jadd -j 4 /mnt/shared   # adds 4 more journals
```

**References:**

- [mkfs.gfs2](https://linux.die.net/man/8/mkfs.gfs2)
- [gfs2_jadd](https://linux.die.net/man/8/gfs2_jadd)
- [GFS2 mount options](https://manpages.debian.org/testing/gfs2-utils/gfs2.5.en.html)
- [Red Hat GFS2 configuration guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_gfs2_file_systems/index)

---

## Phase 5: Dynamic Membership (ASG Integration)

**Goal:** Nodes join and leave without manual intervention or cluster reconfiguration.

### 5.1 — Scale-out (node joins)

ASG launches a new instance → user-data / cloud-init starts `cluster-agent.service`:

```
[Unit]
Description=GFS2 Cluster Agent
After=network-online.target

[Service]
ExecStart=/usr/local/bin/cluster-agent \
    --etcd-endpoints=https://etcd-nlb.internal:2379 \
    --etcd-cert=/etc/cluster-agent/client.crt \
    --etcd-key=/etc/cluster-agent/client.key \
    --etcd-ca=/etc/cluster-agent/ca.crt \
    --volume-id=vol-0abc123def456789 \
    --cluster-name=mycluster
ExecStartPost=/bin/mount -t gfs2 -o lockproto=lock_etcd,locktable=mycluster:sharedfs /dev/nvme1n1 /mnt/shared
ExecStop=/bin/umount /mnt/shared
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### 5.2 — Scale-in (clean node leaves)

Configure an **ASG Lifecycle Hook** on `autoscaling:EC2_INSTANCE_TERMINATING` with a `HeartbeatTimeout` of 120s. This gives the agent time to unmount cleanly before the instance is terminated.

`cluster-agent` registers for the lifecycle hook event (poll SQS or EventBridge) and on receipt:

1. `umount /mnt/shared` — flushes dirty pages, releases all glocks via `lm_unmount()`
2. Delete `/cluster/members/{node_id}` and revoke session lease
3. Call `autoscaling:CompleteLifecycleAction` with result `CONTINUE`

**Reference:** [ASG Lifecycle Hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html)

---

## Phase 6: Testing & Validation

**Goal:** Prove correctness under all failure modes before production use.

### Test matrix

| Scenario | Trigger | Expected behavior |
| --- | --- | --- |
| Clean shutdown | `systemctl stop cluster-agent` | GFS2 unmounts, all glocks released, etcd keys deleted, peers unaffected |
| Hard crash | `kill -9 cluster-agent && halt -f` | Session lease expires after TTL, Watch fires, fencing race, EC2 Stop, journal recovery |
| Hypervisor stall | Suspend VM for 30s (longer than TTL) | Same as crash path; stale wake-up gets glock denied via revision mismatch |
| Network partition (node↔etcd) | `iptables -A OUTPUT -d <etcd-ip> -j DROP` | Node cannot renew lease, lease expires, peers fence it |
| Idle node | No I/O for 10 minutes | Node never fenced; session lease keepalive continues independently |
| Concurrent EX writes | Two nodes write same file simultaneously | GFS2 glock serializes; second waiter gets WAIT then GRANT after first releases |
| Concurrent SH reads | Many nodes read same file | PR glocks all granted simultaneously; no contention |
| etcd leader election | Kill etcd leader mid-operation | Client retries on new leader; linearizability preserved by Raft |
| etcd quorum loss | Kill 2/3 etcd nodes | etcd stops accepting writes; cluster-agent blocks; GFS2 I/O freezes; resumes when quorum restored |
| Stale lock holder | Node pauses > TTL then resumes | Next glock request gets denied (revision mismatch); GFS2 invalidates and re-acquires cleanly |
| Double fencing | Two survivors both try to fence | CAS on `/cluster/fencing/{node}` ensures only one proceeds |
| Fencer crashes mid-fence | Kill fencing node after CAS win, before EC2 call | Short TTL on fencing key expires; another survivor retries the CAS and takes over |

### Tooling

```bash
# Live glock contention monitoring
glocktop -p $(pidof gfs2)

# Dump all glock states (requires debugfs)
mount -t debugfs none /sys/kernel/debug
cat /sys/kernel/debug/gfs2/mycluster:sharedfs/glocks

# Network partition simulation
tc qdisc add dev eth0 root netem loss 100%   # isolate
tc qdisc del dev eth0 root                   # restore

# Netlink message tracing (during development)
# Add pr_debug() calls in letcd_nl_recv() and read via dmesg
```

**References:**

- [GFS2 glock debugging](https://docs.kernel.org/filesystems/gfs2-glocks.html)
- [Jepsen: etcd 3.4.3](https://jepsen.io/analyses/etcd-3.4.3) — exact failure modes to reproduce

---

## Complete Reference Index

### Kernel / GFS2

| Resource | URL |
| --- | --- |
| `lm_interface.h` — the interface to implement | https://elixir.bootlin.com/linux/latest/source/fs/gfs2/lm_interface.h |
| `lock_dlm.c` — template for `lock_etcd` | https://elixir.bootlin.com/linux/latest/source/fs/gfs2/lock_dlm.c |
| `glock.c` — glock state machine | https://elixir.bootlin.com/linux/latest/source/fs/gfs2/glock.c |
| `incore.h` — gfs2_glock, lm_lockstruct | https://elixir.bootlin.com/linux/latest/source/fs/gfs2/incore.h |
| GFS2 glock internals doc | https://docs.kernel.org/filesystems/gfs2-glocks.html |
| GFS2 uevents (recovery) | https://docs.kernel.org/5.19/filesystems/gfs2-uevents.html |
| GFS2 kernel doc | https://docs.kernel.org/6.8/filesystems/gfs2.html |
| Netlink tutorial (Linux Journal) | https://www.linuxjournal.com/article/7356 |
| Kernel Connector / Netlink API | https://www.kernel.org/doc/html/latest/driver-api/connector.html |
| Netlink man page | https://www.systutorials.com/docs/linux/man/7-netlink/ |

### etcd

| Resource | URL |
| --- | --- |
| etcd API guarantees | https://etcd.io/docs/v3.5/learning/api_guarantees/ |
| etcd lease + fencing token | https://etcd.io/docs/v3.5/learning/why/ |
| etcd Go client v3 | https://pkg.go.dev/go.etcd.io/etcd/client/v3 |
| etcd concurrency (sessions) | https://pkg.go.dev/go.etcd.io/etcd/client/v3/concurrency |
| etcd security (mTLS) | https://etcd.io/docs/v3.5/op-guide/security/ |
| Jepsen etcd 3.4.3 analysis | https://jepsen.io/analyses/etcd-3.4.3 |
| etcd fencing token example | https://github.com/etcd-io/etcd/pull/11490/files |

### AWS

| Resource | URL |
| --- | --- |
| EBS Multi-Attach docs | https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volumes-multi.html |
| EC2 IMDSv2 | https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html |
| AWS SDK Go v2 — EC2 | https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2 |
| EC2 StopInstances | https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#Client.StopInstances |
| EC2 DetachVolume | https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#Client.DetachVolume |
| EC2 InstanceStoppedWaiter | https://pkg.go.dev/github.com/aws/aws-sdk-go-v2/service/ec2#InstanceStoppedWaiter |
| ASG Lifecycle Hooks | https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html |

### GFS2 Operations

| Resource | URL |
| --- | --- |
| Red Hat GFS2 config guide (RHEL 9) | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/configuring_gfs2_file_systems/index |
| GFS2 mount options (man page) | https://manpages.debian.org/testing/gfs2-utils/gfs2.5.en.html |
| mkfs.gfs2 | https://linux.die.net/man/8/mkfs.gfs2 |
| gfs2_jadd | https://linux.die.net/man/8/gfs2_jadd |

### Distributed Locking Theory

| Resource | URL |
| --- | --- |
| Martin Kleppmann — How to do distributed locking | https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html |
| Lease pattern in distributed systems | https://singhajit.com/distributed-systems/lease/ |