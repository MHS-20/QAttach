# QAttach

etcd-backed distributed lock manager (DLM) replacement for GFS2 on EBS Multi-Attach.

## Status

Greenfield — no commits, no source code. Single source of truth for design is `docs/general_plan.md` (843 lines, covers every decision). Read it first before writing any code.

## Architecture (tl;dr)

```
lock_etcd (kernel module, lm_lockops impl) ←Netlink→ cluster-agent (Go daemon) ←gRPC→ etcd (3-node Raft)
```

- **`lock_etcd`** — kernel module implementing GFS2's `lm_lockops`. Communicates with `cluster-agent` exclusively via a custom Netlink family. Replaces `lock_dlm`.
- **`cluster-agent`** — Go userspace daemon (one per compute node). Owns all etcd interactions, fencing logic (EC2 `StopInstances`/`DetachVolume`), and Netlink server.
- **etcd** — fixed 3-node cluster behind internal NLB. Single source of truth for membership, glocks, and fencing coordination.
- **GFS2** — unchanged on-disk format. Journals managed entirely on-disk by GFS2 itself (not in etcd).
- **EBS io2 Multi-Attach** — one volume per AZ, block device shared by all compute nodes in that AZ.

## Key constraints (from design doc)

- Fencing is EC2 API-based (`StopInstances`, `DetachVolume`) — no STONITH/IPMI.
- Session lease TTL=15s, keepalive every 5s. Idle nodes are never fenced.
- Fencing token = etcd revision of the lock key, issued on grant, validated on every request.
- No node-to-node monitoring — etcd Watch on `/cluster/members/` and session lease expiry are the sole liveness signals.
- One session lease per node (unconditional keepalive). Per-lock keys are attached to the session lease (auto-deleted on crash).
- etcd key schema: `/cluster/members/{node_id}`, `/cluster/fencing/{node_id}`, `/cluster/epoch`, `/locks/glock/{type}/{number}`.
- Glock mode mapping: EX→EX, SH→PR, DF→CW, UN→delete key.
- The kernel module template is `fs/gfs2/lock_dlm.c` — read it before implementing.

## Environment

From `docs/awscli_info.txt`:

```
region: us-east-1
az: us-east-1a
key_pair_name: muhamad-keypair
pem_path: ~/.ssh/id_ed25519
cluster_name: mycluster
aws_profile: default
```

## AWS provisioning notes

- `docs/setup_aws_cli.md` explains IAM user vs instance role, credential layers, and what the agent can discover vs what the user must provide.
- Three separate credential sets: terminal (IAM user access key), compute nodes (IAM instance role), SSH (EC2 key pair).
- All four compute nodes + EBS volume must be in the same AZ (Multi-Attach is AZ-scoped).
- IAM policy for `cluster-agent` instance role is in `docs/general_plan.md` — requires `ec2:StopInstances`, `ec2:DetachVolume`, `ec2:Describe*`, `autoscaling:CompleteLifecycleAction`.
- Lock down `StopInstances`/`DetachVolume` with `aws:ResourceTag/ClusterName` condition.
- Do not grant `ec2:TerminateInstances` — stopping is sufficient for fencing.

## What exists so far

| Path | Content |
|------|---------|
| `docs/general_plan.md` | Full architecture, design decisions, etcd key schema, IAM policy, phased implementation plan, testing matrix |
| `docs/awscli_info.txt` | AWS environment variables |
| `docs/setup_aws_cli.md` | AWS CLI setup, credential layers, SSH key pair, provisioning workflow |
| `.gitignore` | `*.csv` only |
