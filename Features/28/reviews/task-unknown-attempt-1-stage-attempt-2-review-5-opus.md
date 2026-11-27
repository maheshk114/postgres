---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 2
round: 5
timestamp: "2026-11-27T07:02:07Z"
outcome: "issues_found"
reviewer_model: "claude-opus-5.5"
input_sha256: "7c15e9f3bc5dc7e0fcdb85b235abb42c78ef863ed27afe3993ac4d09a0873510"
---

## Review Summary
- **Round**: 5
- **Theme**: Testing & coverage
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-5-opus.md
- **Issues Found**: 8
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Read `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c:5815-5905`. `get_flush_position` (5819-5867) no longer returns at the first entry that isn't flushed, but it still advances `*flush` and deletes later entries (5849-5854). `store_flush_position` is at 5878-5905.
- [x] Read `worker.c:6240-6300`. `send_feedback` only stops the flush position from going backwards (6276-6277). It reports `recvpos` when nothing is pending (6270-6271).
- [x] Read where `local_end` comes from in `worker.c`:
  - Parallel worker commit at 2898-2920. It publishes `XactLastCommitEnd` at 2914, and the same pattern is at 4320 (streamed commit).
  - Leader commit at 4354-4395, stored at 4393-4394.
  - ROLLBACK PREPARED at 3264-3325: commit-order wait at 3280, `LookupGXact` at 3288, `InvalidXLogRecPtr` stored at 3315-3316.
- [x] Grepped `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/access/transam/xact.c`. A commit with no XID that wrote no WAL takes `goto cleanup` at 1438-1439. That skips the `XactLastCommitEnd = XactLastRecEnd` assignment at 1612; the `cleanup:` label is at 1616.
- [x] Read `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`:
  - 860-905: `pa_free_worker`.
  - 2128-2290: `pa_get_last_commit_end` copies `last_commit_end`; the DSA area is pinned and unpinned; `pa_wait_for_depended_transaction` logs at 2241 and 2285 and sleeps at 2280.
- [x] Grepped callers across `applyparallelworker.c`, `worker.c` and `launcher.c`:
  - `pa_maybe_reuse_worker` is defined at 549 and called only at 693.
  - The "pool full" early return is at 702-704.
  - The only call to `logicalrep_pa_worker_stop` is at 891.
  - The only call to `pa_free_worker` is at 2049, inside `pa_xact_finish` (2028).
- [x] Grepped `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl`:
  - Assertions: 22 are `ok(1, …)`, 33 are `is()`, and 1 is `unlike` at 327. That totals 56, matching the supplied pass count.
  - 23 injection attachments: 21 `parallel-worker-before-commit`, one `parallel-worker-before-prepare` at 608, and one `apply-update-before-open-indices` at 527.
  - Zero matches for `apply_error_count`, `pg_stat_subscription_stats`, `confl_`, `conflict detected`, `ROLLBACK PREPARED`, `synchronous_commit`, `wal_writer`, `flush_lsn`, `confirmed_flush`, `max_parallel_apply_workers`, `->restart` and `->stop`.
- [x] Read 050 at 536-606 (memory limit, then DISABLE/ENABLE), 606-651 (two-phase commit) and 728-797 (unsafe trigger).
- [x] Read `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/015_stream.pl:214-260` and `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/032_subscribe_use_index.pl:652-674`.
- [x] Grepped `max_logical_replication_workers`: `001_rep_changes.pl:20`, `010_truncate.pl:20`, `026_stats.pl:19` and `027_nosuperuser.pl:89`. Also grepped the subscriptions in `010_truncate.pl` (60, 63, 66, 204, 207).
- [x] Took the supplied validation into account: build and install passed, 050 passed 56/56, and the six changed tests passed 117/117. I ran no tests or commands myself, and I did not read any review artifacts or run directories.
- [ ] Runtime reproduction: not done, because this lens is read-only. All findings come from tracing code and reading tests. Issue 1 needs the reproduction proposed below, run by the driver.
- [ ] Mutation check (turn off dependency recording and rerun 050): not done. Issue 2's conclusion comes from tracing code only.
- [ ] Areas not covered in this bounded attempt (20-call budget):
  - The serialization of internal and relation-map messages (`logicalrep_write_all_internal_rels`, `PA_MSG_RELMAP`).
  - The `parallel_apply_suspended` memory-accounting thresholds.
  - dshash locking.
  - The full bodies of `handle_dependency_on_change`, `check_relation_parallel_apply_safety`, `maintain_commit_order_dependency` (`worker.c:8484`) and `apply_handle_commit_prepared` (3213).
  - The body of `pa_xact_finish` (2028). It probably has the same stale-`last_commit_end` pattern as Issue 1.
  - The second deadlock check in 015 (289).
  - How SKIP LSN and `disable_on_error` interact with this change.
  - `*.sgml` documentation.
  - A possible hang between a prepared transaction and a later parallelized transaction on the same rows. I judged it unreachable for workloads that are consistent with the publisher, but did not verify that.

## Issues

### Issue 1: Untested flush-feedback path can report flush past a commit that isn't durable yet (a crash then loses the transaction permanently)
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - Defect: 5819-5867, mainly 5849-5860.
  - Where stale `local_end` values come from: 2912-2914 and 4320 (parallel worker), 4393-4394 (leader), 3288 and 3315-3316 (ROLLBACK PREPARED).
  - Where they are used: 6270-6277.
  - Core behavior relied on: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/access/transam/xact.c:1438-1439, 1612, 1616`.
- **Description**:
  - **Evidence:** code trace only; not reproduced at runtime. No test covers this path.
  - **Defect:** Upstream returned as soon as it reached an entry with `local_end > local_flush`. The patch removes that return (comment at 5856-5860) so it can collect later workers' `local_end`. But the loop still sets `*flush = pos->remote_end` and deletes every later entry whose `local_end <= local_flush`. That is only correct if `local_end` never decreases along `lsn_mapping`, and it can decrease:
    - When a commit has no XID and wrote no WAL, xact.c jumps to `cleanup` (1438-1439) and never runs `XactLastCommitEnd = XactLastRecEnd` (1612).
    - A parallel worker applying such a transaction therefore publishes the end LSN of its previous commit (2914), or 0 if the worker is new (`pa_setup_dsm` initializes the field to Invalid). The leader picks this up through `pa_get_last_commit_end` (or `pa_maybe_reuse_worker`).
    - When the leader applies such a transaction itself, it stores its own stale value (4393). After commit-order hand-offs, that value has no relationship to the workers' commit LSNs.
    - ROLLBACK PREPARED for a GID that `LookupGXact` does not find (3288) writes no WAL but stores `InvalidXLogRecPtr` (3315). The comment at 3310-3314 says "we always flush", which is false on this branch. This branch is reachable even when only the leader applies changes.
  - **Preconditions (defaults):** subscriptions default to `synchronous_commit = off` and `streaming = parallel`. Commits that write no WAL are routine:
    - An UPDATE or DELETE whose target row is missing (update_missing / delete_missing is logged and skipped).
    - An ENABLE REPLICA or ALWAYS BEFORE ROW trigger that returns NULL.
  - **Schedule:** on the subscriber, row id=99 has been deleted locally. The publisher runs T1 `INSERT INTO t VALUES (3)`, then T2 `UPDATE t SET v = v + 1 WHERE id = 99`.
    1. The leader sends T1 to W1 and T2 to W2. W2 also gets `PA_MSG_XACT_DEPENDENCY(T1)` for commit order.
    2. W1 commits asynchronously at local LSN L1, while `GetFlushRecPtr()` is still below L1.
    3. W2 hits update_missing and commits with no XID and no WAL. It publishes a stale or zero `local_end`.
    4. On the leader's next `get_flush_position`, T1's entry is kept because L1 > local_flush. T2's entry passes the check, so `*flush` becomes T2.end and the entry is deleted.
    5. `have_pending_txes` is true, and the clamp only prevents going backwards, so the feedback message reports flush = T2.end.
  - **Observable result:**
    - The publisher slot's `confirmed_flush_lsn` moves past T1.
    - If the subscriber crashes within the async-commit window (up to about 3 × `wal_writer_delay`), T1's commit record is lost.
    - On restart, the subscriber asks to start from its origin LSN, which is before T1. Logical decoding moves the start forward to `confirmed_flush` ("…has been already streamed, forwarding to…"), so T1 is never sent again.
    - T1's rows are missing on the subscriber, silently and permanently.
  - **Refutation check:**
    - CREATE SUBSCRIPTION documents `synchronous_commit = off` as safe because the publisher resends lost transactions. That holds only if the reported flush position never goes beyond a commit that is durable locally.
    - Commit ordering does not save this case. T2 commits after T1, but it writes no WAL record whose flushwould cover T1.
    - PREPARE, COMMIT PREPARED, and ROLLBACK PREPARED when the GID exists are all safe. Core calls `XLogFlush` synchronously for each of them, and that flush also covers all earlier WAL.
    - Upstream's early return is what kept stale values in later entries harmless. With leader-only apply, a stale value equals the leader's own latest commit end, so `local_end` still never decreases. The one exception is the ROLLBACK PREPARED entry for an unknown GID, which the removed early return now lets through.
  - **Classification:** the triggering conflicts are genuine; serial apply logs them the same way. The durability loss is new in this series, through the parallel paths and the leader's ROLLBACK PREPARED path for an unknown GID.
- **Risk**: Replicated data can be lost silently and permanently after a subscriber crash. This needs only default settings and common workloads, such as bidirectional or diverged replicas that hit update_missing/delete_missing, or row-filtering triggers. No error is raised. The only trace is the publisher log line "has been already streamed, forwarding to".
- **Suggested Fix**:
  - Restore prefix semantics in `get_flush_position`:
    - Add `bool blocked = false`.
    - Keep iterating, so parallel workers' `local_end` and `committed_xids` are still collected.
    - Advance `*flush` and delete an entry only while `!blocked && pos->local_end <= local_flush`.
    - Set `blocked = true` at the first entry that fails this check, and add an `Assert` that `*flush` does not change after that.
  - Optionally, when a commit wrote no WAL (including the ROLLBACK PREPARED case with an unknown GID), store `GetXLogInsertRecPtr()` instead of a stale or Invalid value.
  - Regression test (in 050 or a new file):
    1. On the subscriber, set `wal_writer_delay = '10s'` and `wal_writer_flush_after = '1GB'`, and delete id=99 locally.
    2. Attach `parallel-worker-before-commit`. Run T1 (`INSERT`) on the publisher, wait for the injection-point event, then detach.
    3. Run T2 (`UPDATE … WHERE id = 99`) on the publisher and record `$t2_end = $node_publisher->lsn('insert')`.
    4. Wake T1, wait for the update_missing log line, then send a trivial T3 to trigger a feedback message.
    5. If the subscriber's `pg_current_wal_flush_lsn()` is below `(SELECT local_lsn FROM pg_replication_origin_status)`, assert that the publisher slot's `confirmed_flush_lsn < $t2_end`. Because the check is conditional it cannot fail spuriously; it only misses the bug when the WAL writer happens to flush first.

### Issue 2: 050 never exercises the window that dependency tracking exists for, the trigger's "waits before apply" claim is unverified, and 22 of 56 assertions are `ok(1)`
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl
- **Line(s)**:
  - `ok(1)` calls: 214, 230, 307, 382, 432, 483, 635, 698, 784, 850, 893, 943, 1037, 1088, 1158, 1204, 1247, 1315, 1361, 1478, 1563, 1600.
  - `parallel-worker-before-commit` attachments: 191, 279, 357, 406, 461, 514, 668, 762, 823, 871, 915, 1011, 1065, 1113, 1182, 1227, 1271, 1339, 1456, 1541, 1580.
  - Trigger block: 736-797. Comment: 219.
  - Related code: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c:2241, 702-704`.
- **Description**:
  - **Evidence:** from reading the tests and tracing code. No mutation run was done.
  - **(a) The hazard window is never reached.**
    - In every data-dependency block, the depended-on TX-1 is held at `parallel-worker-before-commit`, after all of its changes have been applied.
    - In that state core PostgreSQL already serializes TX-2:
      - Replica-identity lookup uses DirtySnapshot and waits with `XactLockTableWait`.
      - `_bt_check_unique` waits for the in-progress transaction.
      - RI action checks wait in `heap_lock_tuple`.
      - RI insert checks cannot see the uncommitted parent row, so they raise an FK error.
    - So the final `is()` row counts do not depend on dependency tracking at all.
    - Only the DEBUG1 probe can tell the difference, and only by accident: without tracking, TX-2 blocks inside its change before it reaches its commit-order wait, so the probe times out.
    - The header comment names three hazards that are never set up: INSERT→DELETE (delete_missing divergence), DELETE→INSERT (insert_exists), and child row before parent row (FK error). Each needs TX-2 to run before TX-1's change exists. A regression in when a detected dependency is enforced, relative to the depended-on change, would still pass.
  - **(b) The trigger block cannot tell waiting from not waiting.**
    - `regress_trigger_guard_fn` (742-743) never changes data in any ordering. Its `UPDATE … WHERE id = 1` runs only when row 1 is not visible, so it matches nothing.
    - TX-2 never blocks in core. If the claimed pre-apply wait were removed, TX-2 would still reach its commit-order wait on the held TX-1. It would then log the same `wait for depended xid <TX-1>` (2241), which satisfies the check at 781.
    - `is($result, 2)` at 797 gives the same answer in any order.
    - Only line 778 ("found parallel unsafe change") discriminates, and it proves the relation was classified as unsafe, not that anything waited. The claim at 784 is untested.
  - **(c) Assertion quality.**
    - 22 of the 56 supplied passing assertions are unconditional `ok(1)`.
    - A real failure shows up as `wait_for_log` dying after the default 180 s timeout, without naming the property that broke.
    - Nothing checks `apply_error_count`, `confl_*`, or the absence of `ERROR` / `conflict detected` (grep finds 0 hits). An FK-error/restart loop would surface only as a timeout. Update_missing/delete_missing divergence would not surface at all.
  - **(d) The comment at 219 is wrong.** It says "Newly assigned worker also waits", but 050 never changes the default pool size of 2. The third transaction finds no reusable worker, takes the pool-full return at 702-704, and is applied by the leader. The leader's wait path therefore runs only incidentally and is never asserted. (Code trace.)
  - **Refutation check:** point (a) relies only on core tuple-lock, unique-check and RI behaviour under READ COMMITTED. The replica session role does not change any of these.
- **Risk**: No test fails in the situation the feature's central correctness mechanism exists to handle. The supplied 56/56 overstates coverage.
- **Suggested Fix**:
  - Add tests that hold TX-1 *before* it applies its change. Either add an injection point at the start of `apply_handle_insert`/`apply_handle_delete` in parallel workers, or reuse `apply-update-before-open-indices` as at line 527.
    - Example: TX-1 `INSERT id=1` (held), then TX-2 `DELETE id=1`.
    - While TX-1 is held, assert TX-2 has not applied: `pg_locks` shows a non-granted wait on the transaction lock.
    - After wakeup, assert the row count is 0 and `confl_delete_missing = 0`.
    - Add DELETE→INSERT and parent→child FK variants.
  - Make the trigger record what it can see in an audit table, e.g. `INSERT INTO audit SELECT EXISTS (SELECT 1 FROM regress_tab WHERE id = 1)`, and assert `t`.
  - Replace `ok(1)` with probes specific to each dependency kind: emit a distinct DEBUG message per kind that includes the xid. Also assert that `apply_error_count` and `confl_*` are unchanged.
  - Fix the comment at 219, or pin the pool size and assert who applies the third transaction.

### Issue 3: Two-phase ordering is untested while PREPARE is still in a parallel worker, and ROLLBACK PREPARED has no test at all
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl
- **Line(s)**:
  - 050, lines 606-651: attach at 608, wakeup at 637-641, `finish waiting` at 643, `COMMIT PREPARED` at 646.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`:
    - 3213: `apply_handle_commit_prepared`.
    - 3268-3317: ROLLBACK PREPARED path. The wait is at 3280, `LookupGXact` at 3288, and the flush entry at 3315-3316.
- **Description**:
  - **Evidence:** from reading the tests and tracing code.
  - The only two-phase block wakes the PREPARE worker and waits for `finish waiting` before it issues COMMIT PREPARED. So the leader's commit-order wait in COMMIT PREPARED is never needed to cover an in-flight PREPARE.
  - ROLLBACK PREPARED gets 0 grep hits in 050.
  - Correctness depends on the wait at 3280 running before `LookupGXact` at 3288. If that order regresses:
    - **COMMIT PREPARED:** `FinishPreparedTransaction` fails with "prepared transaction with identifier … does not exist". This error happens only in parallel mode and causes a restart.
    - **ROLLBACK PREPARED:** `LookupGXact` returns false, so the rollback is silently skipped. The worker then completes PREPARE, leaving an orphaned `pg_prepared_xacts` entry. It holds locks and the xmin horizon indefinitely, with no error.
  - The branch for an unknown GID also feeds Issue 1.
  - **Refutation check:** core only lets COMMIT/ROLLBACK PREPARED find the GXACT (`LockGXact`/`LookupGXact`) after PREPARE has completed. The subscriber has to reproduce that order across processes.
  - **Classification:** both failure modes would occur only with parallel apply.
- **Risk**: Regressions in two-phase ordering would pass CI. The rollback case causes silent, lasting damage.
- **Suggested Fix**:
  - Hold the worker at `parallel-worker-before-prepare` and run `COMMIT PREPARED` on the publisher. Add a second case that runs `ROLLBACK PREPARED` instead.
  - While the worker is held, assert that the leader is waiting: `pg_locks.granted = false` for the leader's PID, or a log line specific to this wait.
  - Wake the worker, then assert the row counts and that `SELECT count(*) FROM pg_prepared_xacts` returns 0.

### Issue 4: Pooled parallel workers hold worker slots permanently, and the tests raise the limits instead of testing this
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**:
  - 295: design note.
  - 549-585 and 693: workers are only reused.
  - 702-704: pool-full return.
  - 867-899: the stop logic is at 887-895. Its only caller is line 2049, in `pa_xact_finish` (2028).
  - Tests: `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/001_rep_changes.pl:20`, `.../010_truncate.pl:20`, `.../026_stats.pl:19`, `.../027_nosuperuser.pl:89`.
- **Description**:
  - **Evidence:** code trace. Slot starvation was not reproduced.
  - Non-streamed transactions now launch parallel workers. These workers are reused but never stopped:
    - The only stop path is `pa_free_worker` (`list_length(pool) > max/2`), and it runs only when a streamed transaction finishes.
    - A subscription with concurrent traffic therefore keeps up to `max_parallel_apply_workers_per_subscription` idle workers (default 2) for as long as its leader lives.
    - Each idle worker takes a `max_logical_replication_workers` slot (default 4).
    - Upstream kept at most `max/2` (1), and only after large streamed transactions.
  - The series sets the limit to 10 in 001, 026 and 027, and to 7 in 010 (up to five subscriptions). That works around the change rather than testing it.
  - **Schedule (defaults):**
    1. sub1 runs concurrent transactions, using its leader plus 2 workers. sub2's leader is also running. All 4 slots are now in use.
    2. Run `ALTER SUBSCRIPTION sub2 REFRESH PUBLICATION` with a new table.
    3. sub2's tablesync worker keeps logging "out of logical replication worker slots" until sub1's leader restarts. A third subscription's leader cannot start either.
  - **Refutation check:**
    - Slots come from the launcher's fixed-size array.
    - The `AllTablesyncsReady()` gate in `pa_can_start` only blocks new assignments; it does not free any worker.
    - grep found no other caller of `logicalrep_pa_worker_stop`.
  - **Classification:** an operational regression, not data corruption.
- **Risk**: Upgraded deployments sized for the old behaviour can stall table sync or fail to start apply workers. No test or documentation warns about it.
- **Suggested Fix**:
  - Apply the `max/2` trim, or an idle timeout, when non-streamed workers are reused. Alternatively, release idle workers when a launch fails or when `AllTablesyncsReady()` is false.
  - Document the new slot sizing.
  - Keep at least one test at the default `max_logical_replication_workers = 4`:
    1. Create two subscriptions and run concurrent traffic on both.
    2. Run REFRESH PUBLICATION with a new table.
    3. Assert that `wait_for_subscription_sync` succeeds.

### Issue 5: Errors and restarts in non-streamed parallel apply are untested
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**:
  - 2229-2286: the wait loop. The comment at 2263-2275 relies on the leader restarting every worker, and the 1 ms sleep is at 2280.
  - About 2173-2203: `dsa_pin` and `before_shmem_exit(pa_unpin_parallel_apply_dsa)`.
  - 050: the only restart is the DISABLE/ENABLE at 592-604, with nothing in flight.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/015_stream.pl:246, 289`.
- **Description**:
  - **Evidence:** from reading the tests and tracing code.
  - 050 never makes a depended-on worker fail while another worker or the leader is polling in `pa_wait_for_depended_transaction`.
  - The only error paths in the changed tests are 015's deadlocks, and those check only the final row count. In that one scenario the unique index is dropped, so a count of 5002 does catch duplicates.
  - Untested:
    - Waiting workers exit promptly when the leader restarts them.
    - The DSA area is unpinned and recreated, with no leak across repeated leader restarts.
    - Replay is exactly-once and in commit order.
    - `apply_error_count` is updated correctly.
  - Two kinds of failure need separate cases:
    - A genuine schema conflict, such as insert_exists against a local row. Serial apply raises this too.
    - An error that can only happen with parallel apply.
  - The assertion at 604 runs right after ENABLE, before any worker could exist, so it proves little.
- **Risk**: Errors are the common case in production. Hangs, busy-waiting, DSA leaks, or duplicated or missing replays on error would all go unnoticed.
- **Suggested Fix**:
  1. Insert a conflicting row locally on the subscriber.
  2. On the publisher, commit TX-1 (the conflicting insert), then TX-2 (which depends on TX-1), then TX-3.
  3. Wait for the insert_exists ERROR. Assert that `apply_error_count` increased and that nothing is stuck in the dependency wait.
  4. Delete the local row and let the subscriber catch up.
  5. Assert that TX-1 through TX-3 were applied exactly once and in order. Use `track_commit_timestamp = on` with `pg_xact_commit_timestamp`, or an audit trigger stamped from a sequence.
  6. Repeat with an injection point that raises an error, to cover the parallel-only case.

### Issue 6: The 015_stream.pl deadlock check doesn't show which deadlock happened
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/015_stream.pl
- **Line(s)**: 216-217 (stated intent), 233-241, 243, 246-247, 258
- **Description**:
  - **Evidence:** code trace.
  - The second `INSERT values(1)` reaches the leader only because the default pool of 2 is full (applyparallelworker.c:702-704). The test neither pins nor asserts that.
  - The only check is that "deadlock detected" appears after `$offset`.
  - A deadlock between two parallel workers produces the same message, even with only the first INSERT:
    - W2 (TX-a) waits in `_bt_check_unique` on W1's xid.
    - At the streamed COMMIT, W1 takes a commit-order wait on TX-a, through the lock acquisition in `pa_wait_for_depended_transaction`.
  - So the test does not establish the leader-vs-worker deadlock it claims to cover (216-217).
  - **Refutation check:** the deadlock detector reports whichever cycle it finds, and the ERROR text does not name the participants.
- **Risk**: Coverage of leader-vs-worker deadlock handling could disappear without any test failing.
- **Suggested Fix**:
  - Before `COMMIT` (243), poll `pg_stat_activity` for `backend_type = 'logical replication apply worker' AND wait_event_type = 'Lock'`.
  - Match the deadlock DETAIL against the leader's PID.
  - Set `max_parallel_apply_workers_per_subscription = 2` explicitly.

### Issue 7: The 032_subscribe_use_index.pl "HACK" hard-codes which worker applies the change and loses leader coverage
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/032_subscribe_use_index.pl
- **Line(s)**: 664-667
- **Description**:
  - **Evidence:** from reading the test.
  - `wait_for_event('logical replication parallel worker', 'apply-update-before-open-indices')` matches only when a parallel worker applies the UPDATE. After the sync wait at 653 that is normally deterministic.
  - The leader applies the UPDATE instead when `pa_can_start` returns false (apply suspended, a tablesync not ready, or parameters being reread) or when the pool is busy. The test then dies after the 180 s timeout with a misleading message.
  - The original scenario, the leader applying while the replica-identity index is dropped, is no longer covered.
- **Risk**: A brittle failure mode, and lost coverage of the leader path.
- **Suggested Fix**:
  - Poll `pg_stat_activity WHERE wait_event = 'apply-update-before-open-indices'` regardless of backend type.
  - Run the scenario twice: with `max_parallel_apply_workers_per_subscription = 0` (leader) and with the default (parallel worker).

### Issue 8: Parallel-safety classification and leader-side paths are not covered
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl
- **Line(s)**: 736-797, the only unsafe-relation case (trigger defined at 749-757). Related: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c:8484` (`maintain_commit_order_dependency`).
- **Description**:
  - **Evidence:** from reading the diff. I did not re-grep each of the absences below in this attempt.
  - The only unsafe-relation case is a row-level `BEFORE INSERT` trigger with `ENABLE REPLICA`. Apply runs with `session_replication_role = replica`, so REPLICA and ALWAYS triggers fire and ORIGIN triggers do not.
  - Trigger and relation cases not covered:
    - ALWAYS triggers.
    - UPDATE, DELETE and TRUNCATE triggers.
    - Statement-level triggers.
    - Triggers on leaf partitions when publishing through the root.
    - Volatile defaults on columns that exist only on the subscriber.
    - The negative case: an ORIGIN-only trigger must not serialize the relation.
  - Leader branches not covered:
    - The leader applying an unsafe or dependent transaction itself, because the pool is full or apply is suspended.
    - The leader replaying a serialized streamed transaction (`apply_spooled_messages` under `TRANS_LEADER_APPLY`), which also checks for and waits on dependencies.
- **Risk**: Misclassification would go unnoticed. Treating an unsafe relation as safe reorders side effects; treating a safe one as unsafe costs throughput.
- **Suggested Fix**:
  - Loop over every combination of trigger kind and enablement state, asserting that `found parallel unsafe change` is present or absent as expected.
  - Add a variant with pool size 0, or with apply suspended, to cover the leader branch.
  - Add a variant that forces a streamed transaction to be serialized, to cover the spooled-replay branch.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage. Run the proposed reproduction before fixing.
- **How verified**: Not verified yet. The reviewer was read-only and ran no tests.

### Issue 2
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.

### Issue 3
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.

### Issue 4
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage. Needs a design decision on reclaiming pooled workers.
- **How verified**: Not verified yet.

### Issue 5
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.

### Issue 6
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.

### Issue 7
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.

### Issue 8
- **Status**: Open
- **What changed**: pending
- **Why**: Awaiting driver triage.
- **How verified**: Not verified yet.