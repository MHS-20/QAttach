# Netlink Protocol

## Overview

The kernel module (`lock_etcd`) and the userspace daemon (`cluster-agent`) communicate
over a custom AF_NETLINK socket (family 31).  The protocol is a simple request-response
model with asynchronous notifications (BAST).

## Socket Setup

- **Kernel side**: `netlink_kernel_create(&init_net, 31, &cfg)` creates a kernel
  socket for family 31.  The input callback `letcd_nl_recv` processes all incoming
  messages.
- **Userspace side**: `syscall.Socket(AF_NETLINK, SOCK_RAW, 31)` creates a raw
  socket.  The agent sends a REGISTER message so the kernel learns its PID for
  unicast replies.

## Message Format

Every netlink message has a standard `nlmsghdr` (16 bytes) followed by a payload.
The payload always starts with a 4-byte message type (u32 LE), followed by
type-specific data.

```
┌──────────────────────────────────────┐
│  nlmsghdr (16 bytes)                 │
│    .len    = header + payload length │
│    .type   = 31 (netlink family)     │
│    .flags  = 0                       │
│    .seq    = 0                       │
│    .pid    = 0 (to kernel)           │
├──────────────────────────────────────┤
│  message_type (u32, 4 bytes)         │
├──────────────────────────────────────┤
│  payload (struct, variable length)   │
└──────────────────────────────────────┘
```

## Message Types

### REGISTER (11) — agent → kernel

Sent once at startup.  The kernel stores the agent's PID from the netlink
socket metadata (`NETLINK_CB(skb).portid`) so it can unicast replies.

```
Payload: 4 zero bytes (minimum payload to pass size check)
```

The kernel updates agent_pid on EVERY REGISTER message (not just the first).
This fixes the bug where agent restart changes PID and the kernel unicasts
to a dead process.

### MOUNT_REQ (9) — kernel → agent

Sent during `lm_mount()`.  The kernel needs a journal ID from the agent.

```
Payload: struct letcd_mount_req {
    u64  request_id
    u8   cluster_name[32]
    u8   filesystem_name[32]
}
```

The kernel extracts `cluster_name` from the GFS2 lock table string
(`"cluster:filesystem"` → `"cluster"`).  `filesystem_name` is not currently
populated.

### MOUNT_RESP (10) — agent → kernel

Response to MOUNT_REQ with the assigned journal ID.

```
Payload: struct letcd_mount_resp {
    u64  request_id
    s32  jid          // negative on error
    s64  epoch        // cluster epoch at mount time
}
```

The kernel waits up to 60 seconds for this response via a completion.

### LOCK_REQ (1) — kernel → agent

Sent when GFS2 wants to acquire a glock or convert one it holds.

```
Payload: struct letcd_lock_req {
    u64  request_id
    u64  glock_number
    u32  glock_type
    u32  requested_mode  // 1=EX, 2=DF, 3=SH
    u32  lvb_valid       // 1: lvb is the value block to publish
    u32  flags           // LM_FLAG_TRY (0x1), TRY_1CB (0x2), NOEXP (0x4)
    u8   lvb[32]
}
// 64 bytes
```

`lvb_valid` is set when the node holds the glock in EX and it has a value
block, i.e. on an EX down-conversion. The agent stores the LVB in etcd before
the conversion lets anyone else in.

`flags` carries the GFS2 flags that change what the lock manager must do:

- **TRY / TRY_1CB**: never queue. If the lock is not grantable at once the
  agent replies `LOCK_DENY` with reason 7, which the kernel completes as
  `LM_OUT_TRY_AGAIN`. TRY_1CB also sends the holders one BAST first. These
  match DLM's `NOQUEUE` and `NOQUEUEBAST`.
- **NOEXP**: the request is part of journal recovery and may be granted while
  a recovery barrier holds every other request back.

Unlock does not use LOCK_REQ; see LOCK_REL.

### LOCK_GRANT (2) — agent → kernel

Lock was successfully acquired in etcd.

```
Payload: struct letcd_lock_grant {
    u64  request_id
    u32  granted_mode
    u32  lvb_valid       // 1: lvb is the current value block
    s64  etcd_revision
    u8   lvb[32]
}
// 56 bytes
```

If the glock has a value block, the kernel copies `lvb` into it, or zeroes it
when `lvb_valid` is 0 — the equivalent of `DLM_SBF_VALNOTVALID`. A node must
never keep its own copy: a stale resource-group LVB with a valid magic number
passes as current and trips a consistency check.

The kernel remembers `etcd_revision` per glock. If it changed since the last
grant of an inode glock, another node held the lock in between, and the
kernel truncates the inode's cached pages.

### LOCK_DENY (3) — agent → kernel

The request completes without the lock.

```
Payload: struct letcd_lock_deny {
    u64  request_id
    u32  reason
    u8   pad[4]
}
// 16 bytes
```

| Reason | Meaning | Kernel completes with |
|--------|---------|-----------------------|
| 1 | Contended past the agent's wait timeout (120s) | `LM_OUT_ERROR` (EIO) |
| 2 | Stale fencing token (defined, not currently sent) | `LM_OUT_ERROR` |
| 3 | Internal error | `LM_OUT_ERROR` |
| 4 | Stale epoch (defined, not currently sent) | `LM_OUT_ERROR` |
| 5 | Conversion deadlock | `LM_OUT_DEADLOCK`: GFS2 unlocks and retries |
| 6 | Canceled by `lm_cancel` | `LM_OUT_CANCELED` |
| 7 | TRY request not grantable | `LM_OUT_TRY_AGAIN` |

`gfs2_glock_complete` takes an `LM_OUT_*` bitmask, never an errno.

### LOCK_WAIT (4) — agent → kernel

Lock is contended; the agent keeps trying and will send GRANT or DENY.

```
Payload: struct letcd_lock_wait {
    u64  request_id
}
```

The kernel marks the pending request. If no reply arrives within
`LETCD_WAIT_TIMEOUT` (150s, above the agent's 120s) it completes the request
with `LM_OUT_ERROR` itself, so a dead agent cannot leave a process in D-state.

### BAST (5) — agent → kernel

Blocking AST — another node wants this lock. GFS2 should demote to the
target mode once its holders are done.

```
Payload: struct letcd_bast {
    u64  glock_number
    u32  glock_type
    u32  target_mode     // mode to demote to
}
```

The kernel calls `gfs2_glock_cb(gl, target_mode)`. An EX waiter forces
UNLOCKED; an SH or DF waiter forces only SH or DF, as `gdlm_bast` does.

### LOCK_REL (6) — kernel → agent

Unlock: sent from `lm_lock(UNLOCKED)` and from `lm_put_lock`.

```
Payload: struct letcd_lock_rel {
    u64  glock_number
    u32  glock_type
    u32  lvb_valid       // 1: lvb is the value block to publish
    u8   lvb[32]
}
// 48 bytes
```

The agent publishes the LVB, if any, before removing the node's holder entry.

### RECOVERY_OK (7) — agent → kernel

The node that owned `jid` has been fenced and its locks purged: replay its
journal.

```
Payload: struct letcd_recovery_ok {
    u32  jid
}
```

The kernel calls `gfs2_recover_journal()` for that journal. If no filesystem
is mounted, or the journal does not exist, it replies at once with
RECOVERY_DONE and `LM_RD_GAVEUP`.

### UNMOUNT (8) — kernel → agent

Filesystem is unmounting. The agent frees the node's journal slot.

```
Payload: 4 zero bytes
```

### CANCEL (12) — kernel → agent

GFS2 has stopped waiting for a request on this glock (`lm_cancel`). It sleeps
until the request completes.

```
Payload: struct letcd_lock_cancel {
    u64  glock_number
    u32  glock_type
    u32  pad
}
// 16 bytes
```

If the agent is still waiting on the lock it ends the wait and replies
`LOCK_DENY` with reason 6. If the grant already went out, the grant completes
the request, as with a DLM cancel that arrives too late.

### RECOVERY_DONE (13) — kernel → agent

GFS2 finished replaying a journal (`lm_recovery_result`).

```
Payload: struct letcd_recovery_done {
    u32  jid
    u32  result          // 309 = LM_RD_SUCCESS, 308 = LM_RD_GAVEUP
}
```

Sent for every replay, including the one each mount runs on its own journal.

## C/Go Struct Alignment

Critical constraint: Go's `encoding/binary.Write` serializes struct fields
individually without trailing padding.  C structs may have trailing padding
to meet alignment requirements.

Example: `MountResponse` in C is 16 bytes (8 + 4 + 4 padding), but Go's
`binary.Write` produces 12 bytes (8 + 4, no trailing padding).  This causes
the kernel's size check (`plen >= 4 + sizeof(struct)`) to fail silently.

**Rule**: All structs sent from agent to kernel must include explicit padding
fields to match C sizes.  Structs sent from kernel to agent are fine because
the kernel includes padding and Go's `binary.Read` ignores trailing bytes.

## Agent PID Tracking

The kernel stores `agent_pid` to unicast replies.  Before the fix (commit
b44f23d), the kernel only stored the PID on the first REGISTER message
(condition `!agent_pid`).  After agent restart, the new PID was ignored,
causing unicast to the dead PID.  The fix removes the condition, so every
REGISTER updates the PID.
