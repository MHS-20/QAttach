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
      EX: CAS Version=0, Put with one EX holder.
      SH: Get holders, check no EX exists, append SH entry via optimistic lock on Version.
          Fails if an EX holder exists (must request BAST first).
      DF: Like EX, single-holder only.
      Release: Read-modify-write Txn to remove this node's entry.
               If array becomes empty, delete the key.
      Handoff: Txn replaces holder's entry with waiter's entry (mode change),
               or removes holder entry if waiter wants EX.

  bast/{type}/{number}
    Purpose:  BAST request signal from waiter to holder
    Value:    target mode (integer: 1=EX, 2=DF, 3=SH, 0=UNLOCK)
    Lease:    Short lease (15s)
    Writers:  Agent that failed to CAS (waiter)
    Readers:  Holder's agent (WatchLockBast)

  glock/{type}/{number}/next
    Purpose:  Atomic handoff reservation
    Value:    waiter node_id
    Lease:    Very short (5s) — prevents permanent reservation
    Writers:  Holder (in release transaction)
    Readers:  Waiter (watch for priority)
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
