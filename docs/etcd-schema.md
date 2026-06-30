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
    Purpose:  Exclusive lock holder (EX mode)
    Value:    {"owner_node_id":"...","mode":"EX"}
    Lease:    Session lease
    Writers:  Agent when acquiring EX (CAS on Version=0)
    Readers:  All agents (WatchLockKey for retry)

  glock/{type}/{number} → [{"node":"A","mode":"EX"}]  (holder array, single key)
    Purpose:  Per-holder shared lock sub-key (SH/PR mode)
    Value:    {"owner_node_id":"...","mode":"PR"}
    Lease:    Session lease
    Writers:  Agent when acquiring SH (per-node, unique)
    Readers:  None (internal)

  bast/{type}/{number}
    Purpose:  BAST request signal from waiter to holder
    Value:    target mode (integer: 1=EX, 2=DF, 3=SH, 0=UNLOCK)
    Lease:    Short lease (15s)
    Writers:  Agent that failed to CAS (waiter)
    Readers:  Holder's agent (WatchLockBast)

  glock/{type}/{number}/next
    Purpose:  Atomic handoff reservation (proposed)
    Value:    waiter node_id
    Lease:    Very short (5s) — prevents permanent reservation
    Writers:  Holder (in release transaction)
    Readers:  Waiter (watch for priority)
```

## Lock Mode Semantics

### EX (Exclusive) — etcd mode "EX"

- Key: `/locks/glock/{type}/{number}`
- Single key, CAS on creation (Version=0)
- Only one node can hold EX on a given lock
- Used for: superblock during recovery, journal locks, exclusive file writes

### SH (Shared) — etcd mode "PR"

- Keys: `/locks/glock/{type}/{number} → [{"node":"A","mode":"EX"}]  (holder array, single key)
- One sub-key per holder, each attached to its session lease
- Multiple nodes can hold SH simultaneously
- The primary key (`/locks/glock/{type}/{number}`) also exists as a marker
- Used for: superblock after recovery, shared file reads

### DF (Deferred) — etcd mode "CW"

- Uses the EX key (shared exclusive model via CAS)
- Currently not supported for multi-holder

## Lease Management

- **Session lease**: Created by `concurrency.NewSession` at agent startup.
  TTL = 15 seconds.  Keepalive every 5 seconds.  Used for member keys and
  long-lived lock keys.
- **Fencing lease**: Short TTL (60s).  Created during fencing CAS.  Prevents
  stale fencing keys from persisting.
- **BAST request lease**: 15s TTL.  Created when writing a bast request.
  Prevents stale bast requests if the waiter crashes.
- **Handoff token lease**: 5s TTL.  Proposed for atomic handoff.  Short to
  quickly free the slot if the waiter crashes.

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

- **Lock acquisition**: CAS (Version=0) ensures only one writer succeeds.
  All others see the current value and can decide to wait or request BAST.
- **Lock release**: Simple DELETE — atomic in etcd.
- **Fencing**: CAS ensures exactly one survivor fences the failed node.
- **Journal assignment**: CAS ensures unique jid per node.
- **Membership**: Session lease guarantees liveness — if keepalive stops,
  all keys vanish atomically.  No partial state.
