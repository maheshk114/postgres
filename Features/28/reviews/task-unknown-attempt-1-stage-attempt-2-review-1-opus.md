---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 2
round: 1
timestamp: "2026-11-27T07:10:07Z"
outcome: "failed"
reviewer_model: "claude-opus-5.5"
input_sha256: "19f130b914e4a23309826b80bab7acc674774072295002a05b560f399179fe10"
---

## Runner Failure

Ambiguous public review output: repeated Review Summary or Evidence Checklist; preserve all findings and retry with a fresh independent review attempt

## Original Response

I found four issues in the v28 parallel apply series. Two are High: one can silently lose committed transactions on the subscriber after a crash, and one can let the subscriber silently diverge from the publisher. All findings come from reading the code; I did not run or reproduce anything.

## Review Summary
- **Round**: 1
- **Theme**: Broad sweep
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-1-opus.md
- **Issues Found**: 4
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Read `get_flush_position` and `store_flush_position` (/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c:5805-5905). Located every `store_flush_position` and `last_commit_end` producer with `rg -n` (worker.c:2886, 2914, 3111, 3129-3130, 3169, 3242, 3315, 3380, 3451, 4320, 4393).
- [x] Read the leader and worker BEGIN, COMMIT and PREPARE handlers (worker.c:2768-2935, 3084-3200), STREAM COMMIT (4225-4400) and `apply_spooled_messages` (4096-4150). Confirmed the STREAM PREPARE ordering with `rg -n` (3354-3369).
- [x] Read the suspension and dependency code:
  - `maybe_suspend_parallel_apply` and `maybe_resume_parallel_apply` (worker.c:834-896)
  - `check_relation_parallel_apply_safety` (1797-1854)
  - `handle_dependency_on_change` (1855-1990), plus the leader-wait and worker-dispatch tail (2063-2078)
  - `handle_streamed_transaction` and `handle_parallelized_transaction` (2225-2380)
- [x] Read the `apply_handle_truncate` partition loop (worker.c:5600-5665), `logicalrep_rel_check_parallel_safety` (/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c:672-745) and `logicalrep_partition_open` (relation.c:1534-1660). Found the attrmap indexing sites with `rg -n` (relation.c:476-477, 583, 736, 1625-1643, 1789).
- [x] Read these functions in /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c:
  - `pa_get_last_commit_end`, the DSA attach, `pa_wait_for_depended_transaction`, `pa_transaction_committed` and `pa_commit_transaction` (2125-2330)
  - `pa_maybe_reuse_worker` (548-585)
  - the `shared->xid` write in `pa_allocate_worker` (815)
  - the `pa_free_worker` pool-size check (867-889)
- [x] Checked the## Review Summary
- **Round**: 1
- **Theme**: Broad sweep
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-1-opus.md
- **Issues Found**: 4
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] **Scope and baseline.** I reviewed the cumulative 12-patch diff supplied in the prompt (18 files, +5579/−195) against the frozen checkout `/home/maheshbehera/worktrees/postgresql-v28-review` (base 2af6dd3370677d8b06cf2a9eb62f69ba11e12cab).
  - I used the new design header in `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c` as the spec: transaction dependency, commit order, worker interaction and locking.
  - I used only read-only `view` and `grep`. I ran no commands and did not open any review artifact or run directory.
- [x] **Flush-feedback trace (Issue 1).** In `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`:
  - `get_flush_position` at 5818–5867. The loop is 5829–5861, the worker `local_end` collection is 5839–5845, the flush advance and delete is 5849–5854, the "We cannot stop here" branch is 5856–5860, and `delete_replica_identity_entries_for_txns` is called at 5864.
  - `store_flush_position` at 5877–5905.
  - The leader's commit store at 4393–4394, the worker's `last_commit_end` at 2914, ROLLBACK PREPARED at 3315, PREPARE at 3111, 3129–3130 and 3169, and the leader's commit-order wait at 2863.
  - The comment on `pa_get_last_commit_end` in `applyparallelworker.c` (about 2125–2165), worker reuse at 548–585, and the pool-full early return at 702–704.
- [x] **Suspension trace (Issue 2).** In `worker.c`:
  - The 16 MB limit at 658, `maybe_suspend_parallel_apply` at 840–861 (it waits only on the current `winfo`, at 855), and the resume logic at 869–896.
  - `handle_dependency_on_change` at 1868–2078, with the early return at 1918–1919 and the leader's direct wait at 2069–2073.
  - The streamed send-to-parallel path at 2280–2296 (2289) and the replay path at 2360–2365 (2363).
  - The non-streamed BEGIN wait while suspended at 2783–2790.
  - STREAM PREPARE at 3360–3369, `apply_spooled_messages` at 4143, and STREAM COMMIT at 4240–4256.
- [x] **Worker reuse and finish protocol (Issue 3).**
  - In `applyparallelworker.c`: `pa_maybe_reuse_worker` at 548–585 (FINISHED check at 561), the `pa_allocate_worker` xid write at 813–817 (815), and `pa_commit_transaction` at 2311–2321 (xid captured at 2314, FINISHED set at 2317).
  - In `worker.c`: the COMMIT unlock at 2918, `remote_ctx.remote_xid` set at 2960, the PREPARE unlock at 3169–3172, and STREAM PREPARE at 3451–3454.
- [x] **Partition TRUNCATE trace (Issue 4).**
  - In `worker.c`: 5600–5665 (call at 5644–5645) and `check_relation_parallel_apply_safety` at 1806–1854.
  - In `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`: 476–477, 583, 672–745 (out-of-bounds index at 736), 972, 1378, 1534–1660 (1564–1569, 1637–1643, 1646, 1659) and 1789.
- [x] **Replica-role trigger rule.** The trigger filter in `logicalrep_rel_check_parallel_safety` (`relation.c` 692–699) skips internal, DISABLED and FIRES_ON_ORIGIN triggers. That matches which triggers fire under `session_replication_role = replica`. No finding.
- [x] **Candidates I refuted after reading the code.**
  - Stale `remote_xid` during spooled replay: `set_remote_transaction_info` runs at `worker.c` 4240, before replay.
  - Dereferencing a NULL `entry->local_end` in `pa_maybe_reuse_worker`: PREPARE dispatch binds it at 3129–3130, and the streamed path frees the entry.
  - Wrong xid in `pa_commit_transaction`: the xid is captured at 2314, before FINISHED is published.
- [x] **Classification.**
  - Issues 1–3 only occur under parallel apply; serial apply on the base is not affected.
  - Issue 4 is a memory-safety and attribute-mapping defect in new code. Every apply worker reaches it.
  - Not counted as an issue, classified as a genuine schema conflict: after a parallel PREPARE, `pa_commit_transaction` (`worker.c` 3170) removes the xid from `parallelized_txns`. A later transaction that blocks on the prepared transaction's row locks through a UNIQUE or FK constraint that exists only on the subscriber then waits until COMMIT PREPARED, which the blocked apply never reaches. Serial apply hangs the same way.
- [x] **Validation evidence supplied by the driver, not run by me.** Configure with assertions, injection points and TAP passed; `make -j4` and install passed; `050_parallel_apply.pl` passed 56/56; `001_rep_changes`, `010_truncate`, `015_stream`, `026_stats`, `027_nosuperuser` and `032_subscribe_use_index` passed 117/117. None of these exercise the schedules below: an unflushed async parallel commit followed by an empty commit, a streamed transaction while suspended, worker reuse in the PREPARE finish window, or TRUNCATE of a partitioned target with a different leaf layout.
- [ ] **Runtime reproduction.** Not performed; this lens is read-only and cannot run commands. Every finding is code-trace evidence only. The regression tests below are proposals, not results.
- [ ] **Core-server behavior.** I did not reopen these core files in this checkout; the following are cited from upstream knowledge:
  - `RecordTransactionCommit` takes the no-XID, no-WAL `goto cleanup` path, which leaves `XactLastCommitEnd` stale and does not advance the origin.
  - The walsender's `ProcessStandbyReplyMessage` calls `LogicalConfirmReceivedLocation`.
  - `CreateDecodingContext` moves `start_lsn` forward to `confirmed_flush`.
  - `RelationFindReplTupleByIndex` waits on its dirty snapshot only for tuples that already exist.
  - `LockRelease` only warns, and returns false, when the lock is not held.
  - The subscription `synchronous_commit` default is `off`, and the docs promise that lost transactions are sent again.
- [ ] **Areas not covered within the 20-call budget:**
  - Ordering of relmap distribution in `proto.c` and `logicalrep_write_all_internal_rels`.
  - Correctness of unique-key and FK dependency extraction (`check_and_record_local_key_dependency`, `check_and_record_fkey_dependency`, `logicalrep_build_dependent_*`, `get_local_fkeys`), including NULL keys and NULLS NOT DISTINCT.
  - `dependency_mem_usage` accounting and cleanup of `replica_identity_table`.
  - DSA and dshash lifetime across leader restarts and worker crashes.
  - Error recovery, and the full loop in `pa_wait_for_depended_transaction`.
  - Subtransaction and partial-serialization transitions.
  - `ProcessSyncingRelations` being called from parallel workers.
  - **Security-relevant, unverified:** whether the leader's `apply_dispatch` rejects a `LOGICAL_REP_MSG_INTERNAL_MESSAGE` sent by the publisher.
  - The full body of `050_parallel_apply.pl`, and the documentation changes.

## Issues

### Issue 1: get_flush_position can confirm a flush past an earlier commit that is not yet on disk, so a subscriber crash can lose data permanently and silently
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - In `worker.c`: 5829–5861, specifically 5849–5854 and 5856–5860; also 4393–4394, 2914, 3315 and 2863.
  - Related, in `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`: 548–585, 702–704, and the `pa_get_last_commit_end` comment at about 2125–2165.
- **Description**:
  - **What changed.** On the base, `get_flush_position` returns at the first `lsn_mapping` entry whose `local_end > GetFlushRecPtr()`. The patch replaces that `else` branch with "We cannot stop here…" (5856–5860) and keeps iterating. Any later entry with `local_end <= local_flush` then sets `*flush = pos->remote_end` and is deleted (5849–5854).
  - **Which entries can do this.** Commit order is preserved, so later commits that write WAL always have a higher `local_end` and fail the same test. Entries recorded without writing WAL can pass it:
    - 4393–4394 stores `XactLastCommitEnd`, which is stale when the commit wrote no WAL.
    - 2914 copies the stale `XactLastCommitEnd` into `last_commit_end`. This contradicts the comment on `pa_get_last_commit_end`, which says Invalid is reported.
    - 3315 stores `InvalidXLogRecPtr` for a ROLLBACK PREPARED whose gid was never prepared locally.
    - PREPARE entries (3111, 3129–3130, 3169) are not triggers: their WAL is flushed synchronously, which also flushes every earlier commit.
  - **Preconditions.**
    - Defaults: subscription `synchronous_commit = off`.
    - The leader dispatches non-streamed transactions to parallel workers.
    - A transaction that writes no WAL follows a parallel-applied commit that is not yet flushed. This happens when all of its changes are skipped: update_missing or delete_missing, or a relation that is not yet READY (`should_apply_changes_for_rel` is false during table sync, with no conflict needed). A ROLLBACK PREPARED for an unknown gid also qualifies.
  - **Schedule** (`max_parallel_apply_workers_per_subscription = 1`):
    1. T1 (INSERT k=1) is dispatched to W1, which commits asynchronously at L1, where L1 > `GetFlushRecPtr()`.
    2. T2 (UPDATE k=2, a row missing on the subscriber) arrives while W1 is busy. `pa_maybe_reuse_worker` returns false and the pool-full return at 702–704 gives NULL, so the leader applies T2 itself.
    3. T2 hits update_missing, waits for T1 at 2863, commits without writing WAL, and stores a stale `local_end`.
    4. At the next `send_feedback`, T1's entry is kept but T2's passes, so `flush = T2.end_lsn`.
    - With two or more workers, a skipped T2 on W2 reaches the same state through 2914.
  - **Observable.**
    - The publisher slot's `confirmed_flush_lsn` moves past T1's end LSN while T1's commit record on the subscriber is still only in WAL buffers.
    - If the OS crashes, or there is a crash-restart or immediate shutdown before the walwriter flushes, T1 is lost on the subscriber and the origin is restored to before T1.
    - On reconnect, `CreateDecodingContext` logs "…has been already streamed, forwarding to…" and skips T1. The divergence is permanent and silent.
    - This breaks the documented promise for `synchronous_commit = off` that lost transactions are sent again.
  - **Refutation.**
    - No lock or snapshot rule forces T1's asynchronous commit record to disk before T2's no-WAL commit.
    - A no-XID commit does not advance the replication origin.
    - The base cannot reach this state because of its early return.
    - **Classification:** a regression that only occurs under parallel apply. Data-loss class.
  - **Evidence:** code trace only; no runtime reproduction.
- **Risk**: Under default subscription settings, committed publisher transactions can be lost on the subscriber after a crash, and replication reports no error. Transactions with skipped changes are common during initial table sync and under update_missing or delete_missing conflicts, so the trigger is ordinary.
- **Suggested Fix**:
  - **Main fix.** Keep iterating, so that worker `local_end` values and `committed_xids` are still collected for `delete_replica_identity_entries_for_txns`. But once one entry fails `local_end <= local_flush`, set a `flush_blocked` flag:
    - Stop advancing `*flush`.
    - Stop deleting and freeing later entries.
    - Store the collected worker `local_end` in each kept entry and reset its `pa_remote_xid`, so later passes do not query the worker again.
  - **Optionally also:**
    - Make `store_flush_position` keep `local_end` monotonic (record `Max` against the previous entry's `local_end`).
    - Fix the `pa_get_last_commit_end` comment, or report Invalid at 2914 when no WAL was written.
  - **Regression test** (new case in `050_parallel_apply.pl`, non-Windows):
    1. Subscriber settings: pool size 1, `synchronous_commit = off`, `autovacuum = off`, `bgwriter_lru_maxpages = 0`, a large `checkpoint_timeout`.
    2. Hold W1 at the `parallel-worker-before-commit` injection point while it applies T1.
    3. Delete k=2 on the subscriber, then run UPDATE k=2 on the publisher.
    4. SIGSTOP the subscriber's walwriter, then wake the injection point.
    5. Assert that the publisher's `pg_replication_slots.confirmed_flush_lsn` stays below T1's end LSN, captured on the publisher. Today it advances to T2's end.
    6. SIGCONT the walwriter.
    - Optional crash variant: stop the subscriber with `stop('immediate')` before the SIGCONT, restart it, and assert that k=1 exists.

### Issue 2: Dependency checks are skipped for streamed transactions while parallel apply is suspended, which causes silent divergence
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - 1918–1919: early return in `handle_dependency_on_change`.
  - 2280–2296 (2289): streamed chunks forwarded to a parallel worker.
  - 2360–2365 (2363): the replay path.
  - 3360–3369 (replay at 3366, wait at 3369): STREAM PREPARE.
  - 4246–4256 (replay at 4252–4253, wait at 4255): STREAM COMMIT.
  - Related: 658, 840–861 (855), 869–896, 2069–2073, 2783–2790, 4143.
- **Description**:
  - **How suspension works.** Once dependency memory exceeds 16 MB (line 658), `maybe_suspend_parallel_apply` makes `handle_dependency_on_change` return early (1918–1919), so nothing is checked or recorded.
  - **How the design compensates.** Only in two places:
    - On entering suspension, the current `winfo` is told to wait (855).
    - The BEGIN of a non-streamed transaction applied by the leader waits (2783–2790).
  - **Streamed paths have no such wait:**
    - **(A) Serialized replay.** The leader serialized streamed transaction S because `pa_can_start()` is false while suspended. At STREAM COMMIT or STREAM PREPARE it replays S's changes (4252–4253 / 3366) through 2363, hitting the early return. Only afterwards does it wait for commit order (4255 / 3369).
    - **(B) Streaming to a worker.** S is already streaming to worker WS. Its later chunks are forwarded unchecked at 2289, and WS applies them immediately.
  - **Spec conflict.** The header says: "If transactions are streamed but leader decides not to assign parallel apply workers, dependencies are verified when the transaction is committed." That is not true while suspended.
  - **Preconditions:** parallel apply with dependency memory above the limit (roughly 10^5 or more in-flight keys), and a streamed transaction that touches a row written by a parallel transaction that is still in flight.
  - **Schedule:**
    1. T1 is on W1 and slow, or held at an injection point.
    2. T2 is on W2. Midway through T2 the limit is crossed, and W2 is told to wait for T1.
    3. T2's later INSERT R is forwarded without being recorded.
    4. On the publisher, S runs UPDATE R after T2 commits; S is large enough to be streamed. The leader serializes S.
    5. At STREAM COMMIT S, replay finds no R (W2 has not run the INSERT), logs update_missing and skips the change.
    6. The leader then waits for T2, T2 inserts R, and S commits.
  - **Observable.**
    - R keeps T2's values instead of S's, which is silent divergence.
    - If S does DELETE R instead, R is left behind.
    - If T2 deletes R and S inserts R, the result is an insert_exists ERROR and an apply restart. This is a transient error that only occurs under parallel apply.
  - **Refutation.**
    - The dirty-snapshot wait in `RelationFindReplTupleByIndex`, and unique-check waits, only cover tuples that already exist. W2 has not written R yet.
    - Serial apply finishes T2 before replaying S.
    - **Classification:** only occurs under parallel apply. It is not a schema conflict.
  - **Evidence:** code trace only; no runtime reproduction.
- **Risk**: Silent data divergence, or spurious errors, for workloads with large in-flight dependency sets, which is exactly when suspension activates, combined with streamed transactions.
- **Suggested Fix**:
  - In STREAM COMMIT and STREAM PREPARE under TRANS_LEADER_APPLY: when suspended, or when any in-flight transaction had recording stopped, call `maintain_commit_order_dependency(NULL)` before `apply_spooled_messages`.
  - On the TRANS_LEADER_SEND_TO_PARALLEL path: when the early return is hit, send WS one `PA_MSG_XACT_DEPENDENCY` on `get_last_parallelized_xid()` per suspension epoch before forwarding.
  - Alternatively, apply the 855 wait to every caller's `winfo`, not only at the transition into suspension.
  - Then correct or qualify the header text quoted above.
  - **Regression test:** extend the existing suspension scenario in `050_parallel_apply.pl`.
    1. Hold T1 at `parallel-worker-before-commit`.
    2. Make T2 cross the limit with INSERT R as its last change, and wait for the suspension log message.
    3. Set the publisher's `logical_decoding_work_mem` so that S (UPDATE R) is streamed.
    4. Wake T1 and wait for catch-up.
    5. Assert that R matches the publisher and that no update_missing was logged.

### Issue 3: The non-streamed PREPARE path in a worker unlocks `MyParallelShared->xid` after reporting FINISHED, so it can release the wrong xid and leak the prepared transaction's lock
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - `worker.c` 3169–3172: `pa_commit_transaction()` at 3170, unlock at 3172.
  - Related in `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`: 548–585 (561), 813–817 (815), 2311–2321 (2314, 2317).
  - Contrast in `worker.c`: 2918, 2960, 3451–3454.
- **Description**:
  - **The race.** `pa_commit_transaction()` publishes PARALLEL_TRANS_FINISHED (2317). From that point the leader may reuse W1 (`pa_maybe_reuse_worker` at 561) and overwrite `shared->xid` with a new xid Xn (815). Line 3172 then re-reads `MyParallelShared->xid` and calls `pa_unlock_transaction(Xn, AccessExclusiveLock)`.
  - **Why only PREPARE.** The COMMIT path uses `remote_ctx.remote_xid` (2918). STREAM PREPARE (3451–3454) is protected because the leader still waits synchronously for streamed transactions.
  - **Preconditions:** `two_phase = on`, a non-streamed PREPARE applied by a parallel worker, and the leader receiving the next BEGIN inside the window between FINISHED and line 3172.
  - **Schedule:**
    1. W1 finishes PREPARE Xp at 3170 and is preempted.
    2. The leader receives BEGIN Xn, reuses W1, and writes `xid = Xn`.
    3. W1 resumes and unlocks Xn.
  - **Observable:**
    - A WARNING "you don't own a lock of type AccessExclusiveLock".
    - The session lock on Xp (`pg_locks` locktype `applytransaction`) stays held until the pooled worker exits.
    - **Possible escalation, not confirmed:** the header says dependency waits are blocking lock acquisitions. If a successor was already blocked acquiring Xp's lock before 3172, W1 never wakes it. It is released only by a deadlock-detector ERROR once W1 later waits on that successor, followed by an apply restart. If confirmed, raise this to Medium.
  - **Refutation.**
    - `LockRelease` on a lock that is not held only warns.
    - Waiters that arrive after Xp is removed from the dshash do not block.
    - **Classification:** only occurs under parallel apply.
  - **Evidence:** code trace only; no runtime reproduction.
- **Risk**: Spurious warnings and lock-table entries that leak over the life of long-running pooled workers. There is also a possible spurious deadlock error and restart.
- **Suggested Fix**:
  - Unlock `remote_ctx.remote_xid` (set at 2960), or a local copy of `MyParallelShared->xid` taken before `pa_commit_transaction()`.
  - **Regression test:**
    1. Add an injection point between 3170 and 3172.
    2. Use pool size 1 and `two_phase = on`.
    3. On the publisher, run PREPARE TRANSACTION and then a normal transaction, so that W1 is reused while it is held at the injection point.
    4. Wake W1.
    5. Assert there is no "you don't own a lock" WARNING, and no `applytransaction` lock on Xp held by W1's pid.

### Issue 4: TRUNCATE of a partitioned target opens partition map entries with the root's attribute map, causing an out-of-bounds read and a wrong mapping
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - `worker.c` 5644–5645, and 1806–1854.
  - Related in `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`: 1637–1643, 1646 → 476–477, 1659 → 1789, 724–737 (736), 1564–1569.
- **Description**:
  - **The defect.** Line 5644 calls `logicalrep_partition_open(rel, childrel, NULL)` for every leaf. A NULL map means "the leaf's layout matches the root", so 1637–1643 copies the root's attribute map along with the root's `maplen`.
  - **Where it is used.** The leaf's own attribute offsets then index that map:
    - `logicalrep_rel_mark_updatable` (476–477), which yields wrong replica-identity and primary-key mapping.
    - `FindLogicalRepLocalIndex` (1789).
    - `logicalrep_rel_check_parallel_safety`, which at 736 reads `attnums[attnum]` for every leaf column that has a default or is a stored generated column, up to the leaf's `natts`.
  - **Base comparison.** The base truncate path never calls `logicalrep_partition_open`. This call is new and runs in every apply worker, whatever the streaming mode.
  - **Preconditions:** the subscriber target is partitioned, and a leaf's layout differs from the root's (a dropped column or a different column order), and a leaf column has a default.
  - **Schedule:**
    1. On the subscriber, create `p(a int PRIMARY KEY, b int DEFAULT 0) PARTITION BY RANGE (a)`.
    2. Create `c(x int, a int NOT NULL, b int DEFAULT 0)`, drop column `x`, and attach `c`.
    3. On the publisher, run `TRUNCATE p`.
    4. Line 736 reads `attnums[2]` from an array of two elements.
  - **Observable.**
    - Undefined behavior, which Valgrind or ASan would detect.
    - Transiently wrong `updatable`, `localindexoid` and parallel-safety values on the cached entry. These are reset by TRUNCATE's relcache invalidation at the CommandCounterIncrement in `end_replication_step`.
  - **Classification:** a memory-safety defect in new code, not a schema conflict.
  - **Evidence:** code trace only; no runtime reproduction.
- **Risk**: Out-of-bounds reads in a common apply path, possible wrong safety decisions for the TRUNCATE, and risk of a crash when a leaf has many dropped columns.
- **Suggested Fix**:
  - Build `map = build_attrmap_by_name_if_req(RelationGetDescr(rel->localrel), RelationGetDescr(childrel), false)`, pass it in, and free it afterwards. This is the same pattern used at `relation.c` 972 and 1378.
  - Optionally add `Assert(attnum < entry->attrmap->maplen)` at 736.
  - **Regression test:** add the schedule above to `013_partition.pl` or `010_truncate.pl`, followed by an INSERT routed to `c`. Check the row, and run under Valgrind or with the new Assert, which fails today.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage; this reviewer is read-only.
- **How verified**: pending (proposed regression test in Issue 1)

### Issue 2
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage; this reviewer is read-only.
- **How verified**: pending (proposed regression test in Issue 2)

### Issue 3
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage; this reviewer is read-only.
- **How verified**: pending (proposed regression test in Issue 3)

### Issue 4
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage; this reviewer is read-only.
- **How verified**: pending (proposed regression test in Issue 4)