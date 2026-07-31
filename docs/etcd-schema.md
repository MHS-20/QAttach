# etcd Key Schema

All keys are relative (no leading `/`).  Keys attached to the agent's session lease
are automatically deleted if the agent crashes or the node becomes unreachable.

## Key Layout

```
cluster/
  members/{node_id}
    Purpose:  Node liveness registration
    Value:    {"instance_id":"i-...","ip":"172.31.x.y","az":"eu-west-1b"}
    Lease:    Session lease (15s TTL)
    Writers:  Local agent at startup
    Readers:  All agents (WatchMemberDeletions for fencing)

  fencing/{failed_node_id}
    Purpose:  Fencing race — CAS winner gets to fence
    Value:    fencer node_id
    Lease:    Short lease (60s TTL)
    Writers:  Any agent that detects a member deletion (CAS)
    Readers:  All agents (check who won)

  epoch
    Purpose:  Cluster epoch counter (incremented on crash)
    Value:    (empty — revision is the counter)

  journals/{jid}
    Purpose:  Journal slot assignment
    Value:    node_id of the owner
    Lease:    Session lease
    Writers:  Agent at mount time (CAS, tries 0..MaxJournals-1)
    Readers:  None (only written once, read only via CAS failure)

locks/
  glock/{type}/{number}
    Purpose:  Single key per lock with JSON holder array
    Value:    [{"node":"nodeID","mode":"EX"},{"node":"other","mode":"PR"}]
    Lease:    Session lease
    Writers:  Agents acquiring or releasing locks via etcd Txn
    Readers:  All agents (WatchLockKey for contention/retry)

    Rules:
      Acquire/convert: Get holders, reject if any *other* holder's mode
               conflicts (DLM matrix: EX excludes everything; PR and CW are
               compatible only with themselves, so PR and CW exclude each
               other).  Otherwise add or update this node's entry via
               optimistic lock on Version.  A rejected requester keeps any
               entry it already had and waits for a BAST to clear the way.
      Release: Read-modify-write Txn to remove this node's entry.
               If the array becomes empty, the key is deleted — and if
               waiters are queued, the delete and the `/next` reservation
               for the longest-waiting node commit in the same Txn, so no
               node can reclaim the lock in between.

  bast/{type}/{number}
    Purpose:  BAST request signal from waiter to holder
    Value:    "targetMode,waiterID" (e.g. "0,i-0f620a6db190e05ce")
    Lease:    Short lease (15s)
    Writers:  Agent that failed to acquire (waiter)
    Readers:  Holder's agent (WatchBastRequests — PUT events only)
    Note:     targetMode is the mode the holder must demote to, derived
              from the waiter's request the way gdlm_bast does it: an EX
              waiter forces UN, an SH or DF waiter forces only SH or DF.

  glock/{type}/{number}/next
    Purpose:  FIFO handoff reservation (active — enforces lock ordering)
    Value:    waiter node_id
    Lease:    Its own short lease (TTL=5s), not the releasing node's
              session lease — otherwise a designated waiter that dies
              before claiming would block the lock for as long as the
              releasing node stays alive.
    Writers:  Releasing holder (inside ReleaseLock's Txn)
    Readers:  Waiter (ProcessLock)
    Lifecycle: Created atomically with lock key deletion. ProcessLock
               refuses acquisition if the marker names a different node.
               Deleted atomically when the designated node acquires, or
               by that node's retry timeout — a Txn guarded on the value
               so no node can clear another node's reservation.
```

## Lock Mode Semantics

### EX (Exclusive)

- Key: `/locks/glock/{type}/{number}`
- Single holder in the array: `[{"node":"nodeID","mode":"EX"}]`
- CAS on creation (Version=0) ensures only one writer succeeds
- If key exists with any EX holder, CAS fails — waiter must BAST or wait
- Used for: superblock during recovery, journal locks, exclusive file writes

### SH (Shared) — etcd mode "PR"

- Key: `/locks/glock/{type}/{number}`
- Multiple SH entries in the holder array: `[{"node":"A","mode":"PR"},{"node":"B","mode":"PR"}]`
- Acquire: Get current holders → check no EX entry exists → Txn: if Version matches, Put updated array with new SH entry
- Multiple nodes can hold SH simultaneously
- No separate sub-keys — all holders live in the same JSON array
- Used for: superblock after recovery, shared file reads

### DF (Deferred) — etcd mode "CW"

- Same key, single DF entry in the holder array
- Currently not supported for multi-holder

## Lease Management

- **Session lease**: Created by `concurrency.NewSession` at agent startup.
  TTL = 15 seconds.  Keepalive every 5 seconds.  Used for member keys,
  lock keys, and journal keys.
- **Fencing lease**: Short TTL (60s).  Created during fencing CAS.  Prevents
  stale fencing keys from persisting.
- **BAST request lease**: 15s TTL.  Created when writing a bast request.
  Prevents stale bast requests if the waiter crashes.
- **Handoff token lease**: 5s TTL.  Short to quickly free the slot if the
  waiter crashes.

Session expiry is fatal, not recoverable: every member, journal and lock
key hangs off the session lease, so a lapsed lease drops them all at once
while GFS2 still believes it holds the corresponding glocks.  The agent
watches `Session.Done()` and exits immediately so peers fence it.

## Session Lifecycle

```
Agent starts
  → concurrency.NewSession (TTL=15s, keepalive background goroutine)
  → RegisterNode (Put /cluster/members/{id} with lease)
  → AcquireLock (Put /locks/glock/... with lease)
  → AssignJournal (Put /cluster/journals/{jid} with lease)

Agent stops (graceful)
  → DeregisterNode (Delete /cluster/members/{id}, Close session)
  → All leased keys auto-deleted

Agent crashes (ungraceful)
  → Keepalive stops
  → Session lease expires after 15s
  → etcd deletes all keys attached to this lease
  → Other agents detect member key deletion → fencing race
```

## Consistency Guarantees

- **Lock acquisition**: CAS (Version=0) for EX, optimistic-lock Txn for SH.
  Only one writer succeeds per etcd revision.
- **Lock release**: Txn reads holder array, removes entry, Puts or Deletes.
  Atomic per etcd revision.
- **Fencing**: CAS ensures exactly one survivor fences the failed node.
- **Journal assignment**: CAS ensures unique jid per node.
- **Membership**: Session lease guarantees liveness — if keepalive stops,
  all keys vanish atomically.  No partial state.
