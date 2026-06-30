# GFS2 Glock State Machine

## What is a Glock?

A glock (GFS2 lock) is the fundamental synchronization primitive in GFS2. Every
filesystem object (inode, resource group, superblock, journal) has an associated
glock.  GFS2 acquires and releases glocks through the `lm_lockops` interface,
which QAttach implements as `lock_etcd`.

## Lock Types

GFS2 defines lock types by purpose.  The type is part of the lock identity
(`lm_lockname = {ln_type, ln_number}`):

| Type | Name      | Purpose                                      |
|------|-----------|----------------------------------------------|
| 1    | Nondisk   | Superblock — coordinates mount/demount       |
| 2    | Inode     | Per-inode metadata and data locking          |
| 3    | Rgrp      | Resource group allocation                    |
| 4    | Meta      | Filesystem metadata (bitmaps, etc.)          |
| 5    | Iopen     | Inode open/close serialization               |
| 6    | Flock     | POSIX file locks (fcntl)                     |
| 7    | Plock     | Persistent (nfs-exported) file locks         |
| 8    | Quota     | Quota file updates                           |
| 9    | Journal   | Per-journal exclusive access                 |

The superblock lock (type 1, number 0) is the most critical during mount: the
first mounter holds it in EX during journal recovery, then downgrades to SH.
Subsequent mounters acquire it in SH.

The journal lock (type 9, number = journal index) is always EX — each journal
belongs to exactly one node at a time.

## Lock Modes

GFS2 uses 4 lock modes.  These are integers passed between GFS2 and the lock
manager:

| Value | Name      | Meaning                        | etcd Mode |
|-------|-----------|--------------------------------|-----------|
| 0     | UNLOCKED  | No lock held (or release)      | —         |
| 1     | EX        | Exclusive — one holder, write  | EX        |
| 2     | DF        | Deferred — concurrent write    | CW        |
| 3     | SH        | Shared — multiple readers      | PR        |

The etcd mode names differ from GFS2 names for historical DLM reasons:
- EX → "EX" in etcd (one holder, CAS on a single key)
- SH → "PR" in etcd (protected read; uses per-holder sub-keys so multiple
  nodes can hold simultaneously)
- DF → "CW" in etcd (concurrent write)

## Lock Compatibility Matrix

Two locks on the same object can coexist if their modes are compatible:

```
           Holder
            NL  EX  DF  SH
Requester  ┌───┬───┬───┬───┐
    NL     │ ✓ │ ✓ │ ✓ │ ✓ │
    EX     │ ✓ │ ✗ │ ✗ │ ✗ │
    DF     │ ✓ │ ✗ │ ✓ │ ✗ │
    SH     │ ✓ │ ✗ │ ✗ │ ✓ │
           └───┴───┴───┴───┘
```

Key rules:
- EX is incompatible with everything (exclusive).
- SH is compatible with SH only (shared among readers).
- DF is compatible with DF and itself (deferred/concurrent writes).
- NL (unlocked) is compatible with everything (no holder).

When a requester wants a mode that's incompatible with the holder's mode,
the lock manager must either:
1. Ask the holder to demote (BAST), or
2. Make the requester wait (LOCK_WAIT), or
3. Both (BAST the holder, then wait).

## Glock State Transitions

Every glock has two relevant state fields:
- `gl_state` — the current granted mode
- `gl_target` — the mode GFS2 wants (set by the glock work function)

GFS2's glock work function (`gfs2_glock_work_func`) runs periodically and may:
1. Request a higher mode (e.g., SH → EX) when I/O needs it
2. Release the lock (EX → UNLOCK) when I/O is done
3. Respond to a BAST by demoting (EX → SH)

The work function typically calls `letcd_lock(gl, gl_target)` to transition.

### Mount-time Transitions

```
First mounter:
  mount → acquire EX (journal recovery)
       → demote to SH (after recovery complete)
       → hold SH indefinitely

Second mounter:
  mount → wait for superblock to be available (SH or EX→SH transition)
       → acquire SH (join cluster)
       → acquire EX on own journal
```

### I/O Transitions

```
File write:
  gl_state=SH → gl_target=EX → letcd_lock(EX) → agent CAS
  → granted EX → I/O proceeds → letcd_lock(UNLOCK) → release

File read (shared):
  gl_state=NL → gl_target=SH → letcd_lock(SH) → agent CAS
  → granted SH → I/O proceeds
```

## Journal Assignment

Each node needs a unique journal ID (jid) for its on-disk journal.  In DLM,
the first mounter scans journals and assigns slots.  In QAttach, journal IDs
are assigned via etcd CAS at mount time:

1. Agent tries CAS on `/cluster/journals/0` (first fit)
2. If CAS fails (slot taken), tries `/cluster/journals/1`, then `/cluster/journals/2`, ...
3. Once a slot is claimed, the agent responds with that jid
4. If all slots are taken (up to `MaxJournals`), mount fails

The journal key is attached to the agent's session lease — if the agent crashes,
the slot is freed automatically when the lease expires.
