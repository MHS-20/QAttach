# QAttach Code Review Issues

This document outlines the issues found during the architectural and codebase review of the `QAttach` project.

## 🔴 Critical Issues (Will cause filesystem corruption or permanent hangs)

### 1. C/Go Struct Padding Mismatch (Kernel↔Agent IPC Breakage)
Go’s `binary.Write` serializes struct fields sequentially without adding C-style padding. However, the C kernel module casts the netlink payload directly to structs, leading to size and alignment mismatches.
*   **The Bug:** `struct letcd_lock_grant` in C is 24 bytes (due to 4 bytes of padding before the 64-bit `etcd_revision` field). Go writes exactly 20 bytes. 
*   **The Impact:** The kernel module checks `plen >= 4 + sizeof(struct letcd_lock_grant)` (which expects 28 bytes). Since Go only sends 24 bytes total, the kernel **silently ignores** the `LETCD_MSG_LOCK_GRANT` message. The exact same issue breaks `LETCD_MSG_LOCK_DENY`, `LETCD_MSG_LOCK_REL`, and `LETCD_MSG_MOUNT_RESP`. The filesystem will hang indefinitely upon mounting.
*   **Fix:** Add explicit padding fields in your Go structs to match the C ABI (e.g., adding `_ uint32` before `EtcdRevision` in `LockGrant`, and after `Reason` in `LockDeny`).

### 2. Unconditional Return in `watchAndRetry`
*   **The Bug:** In `internal/lock/manager.go:watchAndRetry`, if an etcd `DELETE` event wakes up the watcher, it attempts to acquire the lock. If it fails (because another node won the CAS race), the code hits an unconditional `return`.
*   **The Impact:** The goroutine exits, and the agent stops watching the key. The kernel module is left hanging forever waiting for a lock grant or deny.
*   **Fix:** Remove the `return` statement when `granted` is false, allowing the loop to `continue` watching for the next release.

### 3. Total Lack of Shared (`PR`) Lock Support
*   **The Bug:** The design doc correctly states that `PR` (Protected Read) locks should support multiple concurrent holders. However, `client.go:AcquireLock` hardcodes the transaction condition: `If(clientv3.Compare(clientv3.Version(key), "=", 0))`.
*   **The Impact:** The agent treats every request (including reads) as an Exclusive (`EX`) lock. Concurrent reads across nodes will fail to acquire the lock and queue up, destroying GFS2 performance and potentially causing lock-inversion deadlocks. 
*   **Fix:** Change the etcd schema for locks to a prefix (e.g., `/locks/glock/{type}/{number}/{nodeID} = mode`). For `PR`, allow the transaction to succeed if all existing keys under the prefix are also `PR`.

### 4. Fatal JID Assignment Flaw
*   **The Bug:** In `internal/lock/manager.go`, `HandleMountRequest` assigns an auto-incrementing `nextJID` (starting at 0) to each mount request.
*   **The Impact:** In a distributed setup, every node's agent will independently assign `JID = 0` to itself. All nodes will mount the exact same GFS2 journal, resulting in immediate and catastrophic filesystem corruption.
*   **Fix:** GFS2 is fully capable of finding a free journal dynamically via glocks. The agent should return `JID = -1` (`GFS2_JID_NONE`), and `letcd_mount` should set `ls_jid = letcd_mount_ctx.mount_jid`, allowing the kernel to orchestrate journal allocation securely.

### 5. Journal Recovery is Never Triggered
*   **The Bug:** When a node is fenced, `Fencer.executeFencing` tries to notify the kernel via `signalRecoveryOk(jid)`. However, `f.journalMap` is empty because `Fencer.RegisterJournal` is **never called** anywhere in the codebase. Furthermore, even if the message reached the kernel, `dispatch_recovery_ok` in `kernel/lock_etcd_netlink.c` only prints a log message (`pr_info`). 
*   **The Impact:** GFS2's journal recovery is bypassed. The failed node's journals are never replayed, and its locks remain held in the on-disk state. Any node trying to access those resources will hang permanently.
*   **Fix:** The kernel module must actually trigger GFS2 recovery (e.g., via `kobject_uevent` similar to `lock_dlm`). The agent also needs a mechanism to reliably discover the JID of the failed node (perhaps by storing it in `/cluster/members/{node_id}` upon successful mount).

---

## 🟠 Major Issues

### 6. Asymmetrical / Confusing Netlink Protocol
*   **The Bug:** When the kernel sends a message to the agent, it puts the message type in the Netlink header (`nlmsg_type`) and puts the struct directly in the payload. When the agent sends a message to the kernel, it sets `nlmsg_type` to `LETCD_NETLINK_FAMILY` (31) and prepends the message type to the payload as the first 4 bytes.
*   **The Impact:** This works by sheer accident because the C receive code looks at the payload, while the Go receive code looks at the header. This is extremely fragile and deviates from standard Netlink conventions. 
*   **Fix:** Standardize the protocol. Put the message type in `nlh->nlmsg_type` in both directions and send only the struct in the payload.

### 7. Coalesced Netlink Messages Dropped
*   **The Bug:** `internal/netlink/server.go:Serve()` only parses the very first message inside the `buf` returned by `syscall.Recvfrom`.
*   **The Impact:** If the kernel sends multiple glock requests in quick succession, Netlink may coalesce them into a single read. The agent will silently drop all subsequent messages in the buffer.
*   **Fix:** Loop over the buffer using `syscall.ParseNetlinkMessage(buf[:n])` to process all messages in a single datagram.

### 8. Leaked etcd Locks on Transient Release Failures
*   **The Bug:** In `HandleLockRelease`, if `etcdCli.ReleaseLock` encounters a transient network error, the error is logged and ignored.
*   **The Impact:** Because locks are bound to the node's long-lived session lease, the lock will remain "held" in etcd until the node completely crashes or restarts, unnecessarily starving other nodes.
*   **Fix:** Implement a retry backoff loop for lock releases, or push failed releases into an async retry queue.

---

## 🟡 Minor Issues / Improvements

### 9. Goroutine Context Leaks
`HandleLockRequest` and `HandleMountRequest` spawn background goroutines using `context.Background()`. These operations have no timeout and aren't tied to the agent's lifecycle. If the agent receives a SIGTERM, these goroutines will leak or block during teardown. Pass the server's root context down to these handlers.

### 10. Incomplete C-String Truncation
In `manager.go:cstring`, if the byte array does not contain a null terminator, `string(b)` will include all trailing garbage bytes. Use `bytes.IndexByte(b, 0)` to truncate properly.