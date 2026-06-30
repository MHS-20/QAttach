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
    u8   pad[4]       // C struct padding — must match exactly
}
```

The kernel waits up to 60 seconds for this response via a completion.

### LOCK_REQ (1) — kernel → agent

Sent when GFS2 wants to acquire or release a glock.

```
Payload: struct letcd_lock_req {
    u64  request_id
    u64  glock_number
    u32  glock_type
    u32  requested_mode  // 0=UNLOCK, 1=EX, 2=DF, 3=SH
}
```

Mode 0 (UNLOCK) means release the lock.  All other modes are acquire requests.

### LOCK_GRANT (2) — agent → kernel

Lock was successfully acquired in etcd.

```
Payload: struct letcd_lock_grant {
    u64  request_id
    u32  granted_mode
    u8   pad[4]          // C struct padding
    s64  etcd_revision   // fencing token
}
```

The fencing token (etcd revision) is stored in the glock's private data.
On subsequent LOCK_REQ for the same glock, the kernel validates the token
to detect stale cache after a crash.

### LOCK_DENY (3) — agent → kernel

Lock could not be acquired (error or stale token).

```
Payload: struct letcd_lock_deny {
    u64  request_id
    u32  reason          // 1=contended, 2=stale, 3=error
    u8   pad[4]          // C struct padding
}
```

### LOCK_WAIT (4) — agent → kernel

Lock is contended — kernel should wait for a BAST or retry notification.

```
Payload: struct letcd_lock_wait {
    u64  request_id
}
```

The kernel keeps the glock in a pending state.  When the lock becomes available,
the agent sends a LOCK_GRANT, or the kernel may retry based on its own logic.

### BAST (5) — agent → kernel

Blocking AST — tells the kernel that another node wants this lock.  GFS2
should demote the lock to the target mode or release it.

```
Payload: struct letcd_bast {
    u64  glock_number
    u32  glock_type
    u32  target_mode     // mode to demote to
}
```

The kernel calls `gfs2_glock_cb(gl, target_mode)` which triggers GFS2's
blocking callback.  GFS2 may:
- Comply: downgrade to target mode
- Ignore: if it can't demote (e.g., journal lock)
- Defer: finish current operation first

### LOCK_REL (6) — kernel → agent

Explicit lock release (not the same as UNLOCK mode in LOCK_REQ).

```
Payload: struct letcd_lock_rel {
    u64  glock_number
    u32  glock_type
}
```

### RECOVERY_OK (7) — agent → kernel

Signals that fencing is complete and journal replay is safe.

```
Payload: struct letcd_recovery_ok {
    u32  jid      // journal ID of the recovered node
}
```

### UNMOUNT (8) — kernel → agent

Filesystem is unmounting — agent should release all resources.

```
Payload: 4 zero bytes
```

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
