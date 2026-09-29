# etcd Key Schema

All keys are relative (no leading `/`).  Keys attached to the agent's session lease
are automatically deleted if the agent crashes or the node becomes unreachable.
Lock keys and journal slots are deliberately **not** on the lease: a dead node's
locks must stay in place until it is fenced and its journal replayed.

## Key Layout

```
cluster/
  members/{node_id}
    Purpose:  Node liveness registration
    Value:    {"instance_id":"i-...","ip":"172.31.x.y","az":"eu-west-1b"}
    Lease:    Session lease (15s TTL)
    Writers:  Local agent at startup
    Readers:  All agents (member deletions trigger a recovery scan; a
              journal slot whose owner has no member key needs recovery)

  fencing/{failed_node_id}
    Purpose:  Claim to fence and recover a failed node — the CAS winner does it
    Value:    claiming node_id
    Lease:    Short lease (60s TTL): a claimant that dies is replaced by the
              next scan.  Deleted by the claimant when it finishes or gives up.
    Writers:  Any mounted agent whose scan finds an orphaned journal (CAS);
              a remounting node claims its own ID before adopting its slot
    Readers:  None (CAS failure is the answer)

  epoch
    Purpose:  Cluster epoch counter (incremented after each recovery)
    Value:    (empty — revision is the counter)

  journals/{jid}
    Purpose:  Journal slot assignment
    Value:    node_id of the owner
    Lease:    None — persistent until unmount or recovery
    Writers:  Agent at mount time.  A slot this node already owns is adopted
              first (an earlier run died mounted and this mount replays it);
              otherwise CAS on 0..MaxJournals-1.  Deleted on unmount, or by
              FinishRecovery after a peer replayed it.
    Readers:  Recovery scan (OrphanJournals)

  recovery/{jid}
    Purpose:  Recovery barrier — journal jid awaits replay
    Value:    node_id that owned the journal
    Lease:    None — must outlive the recovering node
    Writers:  The fencing claimant, after fencing and before purging the
              dead node's locks; a remounting node adopting its own slot
    Readers:  ProcessLock.  While any barrier exists only NOEXP requests are
              granted — except that a node passes a barrier naming itself,
              so a mount can proceed while it replays its own journal.  The
              grant Txn compares the barrier prefix's ModRevision, so a
              barrier raised after the check aborts the grant.
    Deleted:  With the journal slot in one Txn when replay succeeds (peer
              recovery), or on the owner's own replay result (adoption)

locks/
  glock/{type}/{number}
    Purpose:  Single key per lock with JSON holder array
    Value:    [{"node":"nodeID","mode":"EX"},{"node":"other","mode":"PR"}]
    Lease:    None — a dead node's entries keep blocking conflicting requests
              until recovery purges them (PurgeHolder)
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
               node can reclaim the lock in between.  With no waiter, the
               lock's value block is deleted in that Txn too.
      Deadlock: A converter (already a holder) blocked by a holder that is
               itself queued as a waiter is denied with reason 5; its
               kernel unlocks and retries from UN, as with DLM -EDEADLK.

  lvb/{type}/{number}
    Purpose:  Lock value block (32 bytes, GDLM_LVB_SIZE)
    Value:    raw bytes
    Lease:    Session lease of the last writer — if the writer dies, the
              value disappears and the next holder sees it as invalid
    Writers:  An EX holder on unlock or down-conversion, before its holder
              entry changes, so no one is granted in between
    Readers:  Every grant (sent to the kernel; absent means invalid)
    Deleted:  When the lock is fully released with no waiter, and by
              PurgeHolder for locks a fenced node held EX

  bast/{type}/{number}
    Purpose:  BAST request signal from waiter to holder
    Value:    "targetMode,waiterID" (e.g. "0,i-0f620a6db190e05ce")
    Lease:    Short lease (15s)
    Writers:  Agent that failed to acquire (waiter)
    Readers:  Holder's agent (WatchBastRequests — PUT events only)
    Note:     targetMode is the mode the holder must demote to, derived
              from the waiter's request the way gdlm_bast does it: an EX
              waiter forces UN, an SH or DF waiter forces only SH or DF.
    Rules:    The holder deletes the key once it has passed the BAST to its
              kernel, guarded on the exact value it read — a waiter may have
              overwritten it in between, and erasing that newer request
              would strand the waiter.  Because the key is consumed, a
              waiter re-writes it on every retry: one request only ever
              reaches one holder, and on a contended glock the lock changes
              hands repeatedly while a waiter waits.  A waiter that gives up
              deletes its own request, again guarded on the value.
              A holder does not act on a BAST until it has held the lock for
              minHoldTime (200ms, mirroring GFS2's gl_hold_time), otherwise
              a lock arriving via a FIFO reservation is demoted before the
              operation that asked for it has run.

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
  waiter keys and value blocks — not for lock keys or journal slots.
- **Fencing lease**: Short TTL (60s).  Created during fencing CAS.  Prevents
  stale fencing keys from persisting.
- **BAST request lease**: 15s TTL.  Created when writing a bast request.
  Prevents stale bast requests if the waiter crashes.
- **Handoff token lease**: 5s TTL.  Short to quickly free the slot if the
  waiter crashes.

Session expiry is fatal, not recoverable: the member key disappears, so
peers treat the node as failed, fence it and replay its journal.  The agent
watches `Session.Done()` and exits immediately.

## Session Lifecycle

```
Agent starts
  → concurrency.NewSession (TTL=15s, keepalive background goroutine)
  → RegisterNode (Put /cluster/members/{id} with lease)
  → AssignJournal on mount (Put /cluster/journals/{jid}, persistent)
  → ProcessLock (Put /locks/glock/..., persistent)

Unmount
  → GFS2 releases every glock (LOCK_REL) → lock entries removed
  → UNMOUNT → journal slot deleted

Agent stops (graceful)
  → DeregisterNode (Delete /cluster/members/{id}, Close session)
  → With the filesystem still mounted, peers treat this as a failure

Node crashes
  → Session lease expires after 15s → member key deleted
  → Its lock entries and journal slot remain
  → A mounted peer claims fencing/{id}, fences it, writes recovery/{jid},
    purges its lock entries, replays the journal, then deletes
    recovery/{jid} and journals/{jid} and increments the epoch
```

## Consistency Guarantees

- **Lock acquisition**: CAS (Version=0) for EX, optimistic-lock Txn for SH.
  Only one writer succeeds per etcd revision.
- **Lock release**: Txn reads holder array, removes entry, Puts or Deletes.
  Atomic per etcd revision.
- **Fencing**: CAS ensures one survivor at a time fences and recovers the
  failed node.  Every recovery step is idempotent, so a repeat after a
  claimant dies is safe.
- **Recovery**: No non-NOEXP grant can commit once a barrier exists; the
  dead node's persistent entries cover the window between lease expiry and
  the barrier.
- **Journal assignment**: CAS ensures unique jid per node.
- **Membership**: Session lease guarantees liveness — if keepalive stops,
  the member key vanishes and recovery starts.
