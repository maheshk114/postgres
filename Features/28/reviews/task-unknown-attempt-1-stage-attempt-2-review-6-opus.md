---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 2
round: 6
timestamp: "2026-11-27T06:57:55Z"
outcome: "failed"
reviewer_model: "claude-opus-5.5"
input_sha256: "ca3519411b8d8c6524bf609cce91ff5550719de3a78d6fe603089181a3245a3c"
---

## Runner Failure

Ambiguous public review output: repeated Review Summary or Evidence Checklist; preserve all findings and retry with a fresh independent review attempt

## Original Response

## Review Summary
- **Round**: 6
- **Theme**: Polish & hardening
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-6-opus.md
- **Issues Found**: 10
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Code-trace, flush reporting:
  - worker.c:5829-5864: `get_flush_position` loop.
  - worker.c:5884-5903: `store_flush_position`.
  - worker.c:2914 and 4320: `last_commit_end = XactLastCommitEnd`.
  - worker.c:3169-3170: PREPARE path.
  - worker.c:4393-4394: leader stores `XactLastCommitEnd`.
  - worker.c:6264-6277: `send_feedback` clamps.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/access/transam/xact.c:1385-1439 and 1612: an xid-less commit skips the `XactLastCommitEnd` update.
- [x] Code-trace, worker launch and pool:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c:689-738, 785-788, 867-895, 346 and 295.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/launcher.c:453-472 and 567.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/utils/misc/guc_parameters.dat:2049 (PGC_SIGHUP).
  - Tests that raised the worker limit: 001_rep_changes.pl:20, 010_truncate.pl:20, 026_stats.pl:19, 027_nosuperuser.pl:89.
- [x] Code-trace, dependency cleanup cost:
  - worker.c:941-969 (full iteration plus `list_member_xid`).
  - applyparallelworker.c:2133-2165 (the "Already collected" path returns true).
- [x] Code-trace, FK metadata rebuild:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c:1163-1180, 1260-1261, 994-1006, 1353, 1365-1387, 1442 and 122-165.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/catalog/heap.c:3851-3852 (core seqscan precedent, used only by TRUNCATE).
- [x] Code-trace, dependency scans and diagnostics:
  - worker.c:1716-1794, 1623-1659 and 1669-1698.
  - worker.c:1076-1104, 1832-1833, 858-899 and 1025-1026.
  - applyparallelworker.c:1080 and 2228-2322.
- [x] Docs checked in the checkout:
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/ref/create_subscription.sgml:343-361
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/logical-replication.sgml:2734-2761
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/config.sgml:5797-5806
- [x] Comments and tests checked:
  - logicalrelation.h:59
  - worker.c:654-679, 1611 and 1798
  - 050_parallel_apply.pl:232, 374-375, 409-425, 690 and 972
  - 032_subscribe_use_index.pl:664
- [x] Driver-supplied validation, not run by me:
  - configure (assertions, injection points, TAP), make -j4 and install passed.
  - 050_parallel_apply.pl passed 56 assertions.
  - The six changed tests passed 117 assertions.
  - None of these covers a crash after an async commit, worker-slot exhaustion, or performance at scale.
- [ ] Runtime reproduction was not done. I had read-only tools only, so every finding is code-trace evidence, not a reproduction.
- [ ] I did not execute any tests; the results above came from the driver.
- [ ] I did not recompute the cumulative diff SHA-256 (no command execution). The review is against the frozen checkout at the lines cited.
- [ ] Uncovered:
  - Whether RI, unique and FK dependency keys are built correctly, including REPLICA IDENTITY FULL and partition attnum mapping in `logicalrep_build_dependent_fkeys`.
  - Deadlock analysis of PA_MSG_XACT_DEPENDENCY and commit-order waits against relation and tuple locks.
  - Classification of replica-role triggers and functions in `logicalrep_rel_check_parallel_safety`.
- [ ] Uncovered:
  - How streaming with partial serialization interacts with pool reuse for non-streamed transactions.
  - Races in distributing the relmap to workers.
  - proto.c and logicalproto.h wire changes, and launcher.c beyond the lines cited.
  - How Issue 1 affects retain_dead_tuples via `wait_for_local_flush` (worker.c:6656).
  - A full typo and pgindent sweep of all 18 files.
  - Benchmarks for Issues 2-4.

## Issues

### Issue 1: `get_flush_position` can report a flush position past an earlier commit that is not yet flushed
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 5829-5864 (deletion and flush advance at 5849-5854, comment at 5856-5860); 2914; 4320; 4393-4394; 6264-6277
- **Description**: The base loop returned at the first entry whose local_end was not flushed yet. v28 keeps iterating so it can collect worker LSNs, but it still deletes any later entry with `local_end <= local_flush` and sets `*flush = pos->remote_end` for it. That is only safe if local_end never decreases along lsn_mapping, and that no longer holds. A transaction that never gets an XID writes no commit record (xact.c:1385-1439 jumps to cleanup and skips line 1612), so the stored `XactLastCommitEnd` is stale: 0 for a fresh parallel worker, or an older commit by the leader or worker.
  - **Preconditions (all defaults)**: streaming=parallel, subscription synchronous_commit=off, at least one parallel apply worker.
  - **Schedule**:
    1. T1 `INSERT (1)` goes to worker A, which commits at local LSN L1. The commit is async and not flushed yet.
    2. T2 deletes a row that is absent on the subscriber (delete_missing, no XID). update_missing, or changes to a table not yet READY, behave the same. A fresh worker B applies it, or the leader does after waiting for commit order.
    3. The leader runs `get_flush_position`. It keeps T1 (L1 > flush), deletes T2 (local_end 0 or stale), and sets flush to T2's end. Because have_pending_txes is true, lines 6270-6277 do not clamp it.
    4. The walsender writes T2's end into the slot's confirmed_flush.
    5. The subscriber crashes before the WAL writer flushes L1.
  - **Observable**: The replication origin is WAL-logged in T1's commit record, which was lost, so after restart it points before T1. The walsender moves the start point forward to confirmed_flush (core decoding "already streamed, forwarding" behavior, which I know from core rather than re-read here). T1 is never re-sent, and the divergence is permanent and raises no error.
  - **Refutation**: No lock, snapshot or protocol rule stops this. Core relies on the subscriber never reporting a flush position beyond a durable local commit, which is exactly what the base early return guaranteed. Prepared entries are safe, because PREPARE is always flushed and is ordered after T1.
  - **Classification**: Parallel-only regression; it is not a schema conflict. Leader-only apply stores that process's latest commit, so values never go backwards there.
  - **Evidence**: Code-trace only.
- **Risk**: Committed upstream data can be lost silently and permanently on the subscriber after a crash, with default settings. The publisher may also recycle the WAL needed to resend it.
- **Suggested Fix**:
  - Once the loop sees an entry with local_end > local_flush, stop deleting entries and stop advancing `*flush`. Keep going only to collect worker LSNs and update `*write`.
  - Alternatively, store and collect `local_end = Max(local_end, predecessor local_end)`.
  - Fix the comment at 5856-5860 and add an Assert for the invariant.
  - Regression test in 050_parallel_apply.pl:
    1. Set wal_writer_delay=10s, the maximum wal_writer_flush_after, autovacuum=off and debug2 logging.
    2. Hold T1 at 'parallel-worker-before-commit' so T2, a delete of a missing row, goes to a fresh worker or to the leader.
    3. Wake T1 and assert that the logged "sending feedback ... flush" value stays below T2's end until the subscriber's flush LSN covers T1.
    4. Then run stop('immediate'), start, catch up, and assert that row 1 exists.

### Issue 2: Each BEGIN retries a worker launch that cannot succeed (16MB DSM created and destroyed, plus a WARNING), and the pool never shrinks
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 689-738 (`==` check at 702-704, `pa_setup_dsm` at 717, launch at 724, cleanup at 733-737); 785-788; 346; 295; 867-895
- **Description**: Non-streamed transactions now call `pa_allocate_worker` at every BEGIN (worker.c:2776 and 2964). Only `pa_can_start` gates that call, and it neither checks slot availability nor backs off after a failure. When no pooled worker is reusable and the pool is below max, `pa_setup_dsm` creates a segment for a 16MB queue before `logicalrep_worker_launch` finds there is no slot. The launch then emits WARNING "out of logical replication worker slots" (launcher.c:464-471) or "out of background worker slots" (567), and the segment is destroyed.
  - **Preconditions (defaults)**: max_logical_replication_workers=4, max_parallel_apply_workers_per_subscription=2, two subscriptions.
  - **Schedule**:
    1. Leaders L1 and L2 start.
    2. sub1 sees overlapping transactions and launches two workers, using all 4 slots. These workers are never stopped (line 295); trimming at 887-889 only runs on the streaming path.
    3. Every sub2 transaction then sees an empty pool, so `0 == 2` is false. It creates the DSM, gets the WARNING, destroys the DSM, and applies serially.
  - **Observable**: One WARNING per replicated transaction, plus a DSM create/destroy and an exclusive LogicalRepWorkerLock scan in the leader, which is the serial bottleneck.
  - **Idle slots also block tablesync**: The same idle workers starve tablesync after REFRESH PUBLICATION; it warns every wal_retrieve_retry_interval and never finishes until a restart. Base PostgreSQL kept at most max/2 idle workers.
  - **GUC lowered on reload (PGC_SIGHUP)**: If max_parallel_apply_workers_per_subscription is lowered below the current pool size, the `==` check never matches again. Every BEGIN that finds all workers busy then pays for the DSM, while the launcher returns false silently (launcher.c:453-458). The excess workers are never stopped.
  - **Evidence that default slots no longer suffice**: the series raised max_logical_replication_workers in 001:20, 010:20, 026:19 and 027:89.
  - **Refutation**: Core throttles tablesync and apply launches with wal_retrieve_retry_interval. Base parallel apply only tried to launch once per large streamed transaction.
  - **Classification**: Parallel-only operational regression, not a schema conflict.
  - **Evidence**: Code-trace; the cost has not been measured.
- **Risk**: The log can grow by gigabytes per day at moderate TPS. Throughput collapses on the subscription that cannot get workers. Tablesync starves with default GUCs.
- **Suggested Fix**:
  - Back off after a launch failure (for example, wait wal_retrieve_retry_interval, or until a worker exits).
  - Reserve a slot before `pa_setup_dsm`.
  - Use `>=` in the quick check.
  - Stop excess idle workers when the GUC is lowered or while `!AllTablesyncsReady()`.
  - Regression test:
    1. Set max_logical_replication_workers=3 and max_parallel_apply_workers_per_subscription=1, with two subscriptions.
    2. Fill sub1's pool using the injection point.
    3. Run 20 small transactions on sub2 and assert there are at most 1-2 slot WARNINGs, not about 20.
    4. In a second case, lower the GUC with a reload and assert the pool is trimmed.

### Issue 3: The feedback path rescans the whole dependency table with already-collected xids on every call
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 5829-5864; 941-969 (957-961); 6089; 6264
- **Description**: Several costs add up on every feedback call:
  - After a worker's local_end is collected, `pos->pa_remote_xid` stays set. `pa_get_last_commit_end` then returns true for it (applyparallelworker.c:2143-2145), so every entry that is retained but not yet flushed is appended to committed_xids again on every call.
  - `delete_replica_identity_entries_for_txns` then visits every bucket and calls `list_member_xid` for each entry, which is O(capacity + N×M). Simplehash never shrinks, so capacity stays at its high-water mark.
  - The base early exit when walking lsn_mapping was removed.
  - **Preconditions**: A high rate of small non-streamed transactions with synchronous_commit=off, so M is roughly the number of commits within the WAL flush lag.
  - **Schedule**: Sustained load. The apply loop calls `send_feedback` each time the socket drains (6089), and each call repeats the same scan.
  - **Observable**: Leader CPU goes to `get_flush_position` and `list_member_xid`, and apply lag grows.
  - No lock or snapshot rule is involved; this is purely performance.
  - **Classification**: Parallel-only performance issue.
  - **Evidence**: Code-trace; not measured.
- **Risk**: The single leader becomes CPU-bound on exactly the workloads parallel apply is meant to speed up.
- **Suggested Fix**:
  - Set `pa_remote_xid = InvalidTransactionId` once the xid has been queued for cleanup.
  - Skip the table walk when no xid is newly collected.
  - Use an xid hash set or a sorted array, or keep per-xid key lists.
  - Restore an early exit, together with the Issue 1 fix.
  - Regression check: a DEBUG2 counter or assertion that each xid is cleaned exactly once across repeated `send_feedback` calls, plus a pgbench-style CPU comparison.

### Issue 4: `get_local_fkeys` scans all of pg_constraint, once per leaf partition, on every relmap invalidation
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c
- **Line(s)**: 1163-1180 (1176); 1260-1261; 994-1006; 1353; 1365-1387; 1442; 122-165
- **Description**: `get_local_fkeys` scans pg_constraint without an index (InvalidOid at 1176). For each matching FK it also calls `find_all_inheritors` and does a full scan of LogicalRepRelMap (994-1006). `logicalrep_build_dependent_fkeys` repeats all of this for every leaf partition (1365-1387).
  - The cached FK info is dropped on any relcache invalidation of the table or a reset (144 and 162). That includes autovacuum and analyze in-place pg_class updates. Invalidating a partition also invalidates its parent (1442).
  - pg_constraint also holds NOT NULL constraints (PG 18+), so it can be large.
  - The core seqscan precedent (heap.c:3851-3852) is used only for TRUNCATE.
  - **Preconditions**: A partitioned table with P leaves, a large pg_constraint, and subscriber autovacuum running.
  - **Schedule**: After an autoanalyze of one partition, the next change to any partition triggers P full catalog scans in the leader.
  - **Observable**: Periodic leader stalls and lag spikes.
  - **Classification**: Parallel-only performance issue.
  - **Evidence**: Code-trace; not benchmarked.
- **Risk**: Lag spikes that scale with P × the size of pg_constraint, triggered by routine maintenance.
- **Suggested Fix**:
  - Use `RelationGetFKeyList()` for the referencing side.
  - For the referenced side, do a single scan per rebuild that matches confrelid against a hash of the leaf OIDs.
  - Replace the full relmap scan with a lookup keyed by local OID.
  - Consider invalidating from a pg_constraint syscache callback instead.
  - Regression check: a 50-partition TAP case with a DEBUG2 message per scan, asserting one scan per rebu## Review Summary
- **Round**: 6
- **Theme**: Polish & hardening
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-6-opus.md
- **Issues Found**: 10
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Code-trace, flush reporting:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c lines 5829-5864, 5884-5903, 2914, 4320, 3169-3170, 4393-4394 and 6264-6277.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/access/transam/xact.c lines 1385-1439 and 1612: a commit with no XID skips the `XactLastCommitEnd` update.
- [x] Code-trace, worker launch and pool:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c lines 689-738, 785-788, 867-895, 346 and 295.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/launcher.c lines 453-472 and 567.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/utils/misc/guc_parameters.dat line 2049 (PGC_SIGHUP).
  - Tests that raise the worker limit: 001_rep_changes.pl:20, 010_truncate.pl:20, 026_stats.pl:19, 027_nosuperuser.pl:89.
- [x] Code-trace, dependency cleanup cost: worker.c lines 941-969; applyparallelworker.c lines 2133-2165.
- [x] Code-trace, foreign-key metadata rebuild:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c lines 1163-1180, 1260-1261, 994-1006, 1353, 1365-1387, 1442 and 122-165.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/catalog/heap.c lines 3851-3852.
- [x] Code-trace, scans, diagnostics and wait loop:
  - worker.c lines 1716-1794, 1623-1659, 1669-1698, 1076-1104, 1832-1833, 858-899 and 1025-1026.
  - applyparallelworker.c lines 1080 and 2228-2322.
- [x] Docs viewed in the checkout:
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/ref/create_subscription.sgml lines 343-361.
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/logical-replication.sgml lines 2734-2761.
  - /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/config.sgml lines 5797-5806.
- [x] Comments and tests viewed:
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/include/replication/logicalrelation.h line 59.
  - worker.c lines 654-679, 1611 and 1798.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl lines 232, 374-375, 409-425, 690 and 972.
  - /home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/032_subscribe_use_index.pl line 664.
- [x] Driver-supplied validation, not run by me:
  - configure, make -j4 and install passed.
  - 050_parallel_apply.pl passed 56 assertions.
  - The six changed tests passed 117 assertions.
  - None of these exercises a crash after an async commit, worker-slot exhaustion, or large scale.
- [ ] Runtime reproduction was not done; I had read-only tools only. Every finding is code-trace evidence, not a runtime reproduction.
- [ ] I did not execute any tests; the results above were supplied by the driver.
- [ ] I did not recompute the cumulative diff SHA-256, because I could not run commands. The review is against the frozen checkout at the lines cited.
- [ ] Not covered, dependency correctness:
  - Whether replica identity, unique and foreign-key dependency keys are correct, including REPLICA IDENTITY FULL and partition attnum mapping.
  - The deadlock graph between dependency and commit-order waits and relation or tuple locks.
  - How replica-role triggers and functions are classified for parallel safety.
- [ ] Not covered, remaining areas:
  - How streaming with partial serialization interacts with reuse of pooled workers for non-streamed transactions.
  - Races when distributing relation-map information to workers.
  - proto.c and logicalproto.h, and launcher.c beyond the cited lines.
  - What Issue 1 does to retain_dead_tuples (worker.c:6656).
  - A full typo and pgindent sweep of all 18 files.
  - Benchmarks.

## Issues

### Issue 1: get_flush_position can report a flush past an earlier commit that is not yet flushed
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 5829-5864 (5849-5854, comment 5856-5860); 2914; 4320; 4393-4394; 6264-6277
- **Description**:
  - **What changed**: The base loop returned at the first entry whose local_end was not yet flushed. v28 keeps iterating and still deletes any later entry with `local_end <= local_flush`, setting `*flush` to that entry's remote_end.
  - **Why that is unsafe**: It assumes local_end only increases along lsn_mapping, and that no longer holds. A transaction that never gets an XID writes no commit record: xact.c:1385-1439 jumps to cleanup and skips line 1612. The stored `XactLastCommitEnd` is then stale: 0 for a fresh worker, otherwise an older commit by the leader or worker.
  - **Preconditions (all defaults)**: streaming=parallel, synchronous_commit=off, at least one parallel apply worker.
  - **Schedule**:
    1. T1 `INSERT (1)` goes to worker A, which commits at local LSN L1 asynchronously; L1 is not flushed yet.
    2. T2 deletes a row that does not exist on the subscriber (delete_missing), so it gets no XID. update_missing, or changes skipped for a table not yet READY, behave the same way. T2 is applied by a fresh worker B, or by the leader after its commit-order wait.
    3. During feedback, T1 is kept, T2 is deleted, and flush becomes T2's end. have_pending_txes is true, so the checks at 6270-6277 do not hold it back.
    4. The walsender sets confirmed_flush to T2's end.
    5. The subscriber crashes before the WAL writer flushes L1.
  - **Observable**: The replication origin was WAL-logged in T1's lost commit record, so it rewinds to before T1. The walsender moves the start point forward to confirmed_flush (core decoding behavior from my knowledge; not re-read in this run). T1 is never resent: the divergence is silent and permanent.
  - **Refutation**: No lock, snapshot or protocol rule prevents this. Core relies on the subscriber never reporting a flush position beyond a durable local commit, which is the invariant the base early return enforced. PREPARE entries are safe because PREPARE is always flushed and is ordered after T1.
  - **Classification**: Regression specific to parallel apply, not a schema conflict. When only the leader applies, the stored value is that same process's latest commit, so it never goes backwards.
  - **Evidence**: Code-trace only.
- **Risk**: Silent, unrecoverable loss of committed upstream data after a subscriber crash, with default settings.
- **Suggested Fix**:
  - Once the loop sees an entry that is not yet flushed, stop deleting entries and stop advancing `*flush`. Keep going only to collect worker LSNs and update `*write`. Alternatively, store `Max(local_end, predecessor local_end)`.
  - Fix the comment at 5856-5860 and add an Assert for the invariant.
  - Regression test in 050_parallel_apply.pl:
    1. Set wal_writer_delay=10s, the maximum wal_writer_flush_after, autovacuum=off and debug2 logging.
    2. Hold T1 at the `parallel-worker-before-commit` injection point, so that T2 (delete of a missing row) goes to a fresh worker or to the leader.
    3. Wake T1. Assert that the flush value in the "sending feedback" log line stays below T2's end until the subscriber's flush LSN covers T1.
    4. Run `stop('immediate')`, start the node, catch up, and assert that row 1 exists.

### Issue 2: Every BEGIN retries a worker launch, creating and destroying a 16MB shared-memory segment and logging a WARNING, and the pool never shrinks
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 689-738 (702-704, 717, 724, 733-737); 785-788; 346; 295; 867-895
- **Description**:
  - **Mechanism**: `pa_allocate_worker` now runs on every non-streamed BEGIN (worker.c:2776 and 2964). `pa_can_start` neither checks for free worker slots nor backs off after a failure. If no pooled worker can be reused and the pool is below its maximum, `pa_setup_dsm` creates a segment with a 16MB queue. Only then does `logicalrep_worker_launch` find there is no slot: it logs "out of logical replication worker slots" (launcher.c:464-471) or "out of background worker slots" (launcher.c:567), and the segment is destroyed.
  - **Preconditions (defaults)**: max_logical_replication_workers=4, max_parallel_apply_workers_per_subscription=2, two subscriptions.
  - **Schedule**:
    1. Both leaders start.
    2. Overlapping transactions on sub1 launch two parallel workers, using all 4 slots. These workers are never stopped: see line 295, and the trimming at 887-889 runs only for streamed transactions.
    3. On every sub2 transaction the pool is empty and the `0 == 2` check is false, so it creates the segment, logs the WARNING, destroys the segment and applies the transaction serially.
  - **Observable**: One WARNING per transaction, plus shared-memory churn and an exclusive LogicalRepWorkerLock scan inside the leader.
  - **Tablesync starvation**: The same idle slots block table synchronization after REFRESH PUBLICATION. It logs a WARNING every wal_retrieve_retry_interval and never completes until restart. Base PostgreSQL kept at most max/2 idle workers.
  - **Lowering the limit on reload**: The GUC is PGC_SIGHUP (guc_parameters.dat:2049). If it is lowered below the current pool size, the `==` check never matches again. Whenever all workers are busy, the segment churn repeats while the launcher returns false silently (launcher.c:453-458), and the extra workers are never stopped.
  - **Supporting evidence**: The series raised max_logical_replication_workers in tests 001:20, 010:20, 026:19 and 027:89.
  - **Refutation**: Core throttles tablesync and apply launches with wal_retrieve_retry_interval. Base parallel apply only tried to launch once per large streamed transaction.
  - **Classification**: Operational regression specific to parallel apply.
  - **Evidence**: Code-trace; the cost was not measured.
- **Risk**:
  - The log can grow by gigabytes per day at moderate transaction rates.
  - Throughput collapses on the subscription that cannot get workers.
  - Tablesync starves with default settings.
- **Suggested Fix**:
  - Back off after a failed launch.
  - Reserve a slot before calling `pa_setup_dsm`.
  - Use `>=` instead of `==`.
  - Stop extra idle workers when the GUC is lowered or while `!AllTablesyncsReady()`.
  - Test:
    1. Configure max_logical_replication_workers=3 and max_parallel_apply_workers_per_subscription=1 with two subscriptions.
    2. Fill sub1's pool using the injection point.
    3. Run 20 transactions on sub2 and assert there are at most 1-2 slot WARNINGs rather than about 20.
    4. Lower the GUC with a reload and assert the pool is trimmed.

### Issue 3: The feedback path rescans the whole dependency table for already-collected transactions on every call
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 5829-5864; 941-969 (957-961); 6089; 6264
- **Description**:
  - **Cause**: `pa_remote_xid` stays set after its local_end has been collected, and `pa_get_last_commit_end` returns true for it again (applyparallelworker.c:2143-2145). So every kept but unflushed entry adds its xid to the cleanup list on every call.
  - **Cost**: `delete_replica_identity_entries_for_txns` then walks every hash bucket and calls `list_member_xid` on each entry. That is O(capacity + N×M), and the simplehash table never shrinks. The base code's early exit was also removed.
  - **Preconditions**: A high rate of small non-streamed transactions with synchronous_commit=off.
  - **Schedule**: Sustained load; `send_feedback` runs each time the socket is drained (6089).
  - **Observable**: The leader spends CPU in `get_flush_position` and `list_member_xid`, and apply lag grows.
  - **Refutation**: No lock or snapshot rule is involved.
  - **Classification**: Performance issue specific to parallel apply.
  - **Evidence**: Code-trace; not measured.
- **Risk**: The leader becomes CPU-bound on exactly the workloads parallel apply is meant to speed up.
- **Suggested Fix**:
  - Clear `pa_remote_xid` once it has been queued.
  - Skip the table walk when nothing new was collected.
  - Use an xid hash set or sorted array, or keep a per-xid list of keys.
  - Restore the early exit together with the Issue 1 fix.
  - Check: a DEBUG2 counter or assertion that each xid is cleaned up once, plus a pgbench CPU comparison.

### Issue 4: get_local_fkeys scans all of pg_constraint, once per leaf partition, on every relation-map invalidation
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c
- **Line(s)**: 1163-1180 (1176); 1260-1261; 994-1006; 1353; 1365-1387; 1442; 122-165
- **Description**:
  - **Cost per rebuild**: pg_constraint is scanned without an index (1176). For each foreign key, the code also calls `find_all_inheritors` and does a full scan of LogicalRepRelMap (994-1006). All of this is repeated for every leaf partition (1365-1387).
  - **What triggers a rebuild**: Any relcache invalidation or reset clears the cache (144, 162), including the in-place pg_class updates from autovacuum and analyze. Invalidating a partition also invalidates its parent (1442).
  - **Catalog size**: Since PG 18, pg_constraint also holds NOT NULL constraints, so it can be large.
  - **Core precedent**: Core uses an unindexed scan of pg_constraint only for TRUNCATE (heap.c:3851-3852).
  - **Preconditions**: A partitioned table with P leaves, a large pg_constraint, and autovacuum running on the subscriber.
  - **Schedule**: Autoanalyze of one partition; the next change to any partition then causes P full catalog scans in the leader.
  - **Observable**: Periodic stalls and lag spikes.
  - **Classification**: Performance issue specific to parallel apply.
  - **Evidence**: Code-trace; not benchmarked.
- **Risk**: Lag spikes that scale with P times the size of pg_constraint, triggered by routine maintenance.
- **Suggested Fix**:
  - Use `RelationGetFKeyList()` for the referencing side.
  - For the referenced side, do one scan per rebuild and match confrelid against a hash of the leaf OIDs.
  - Look up relation-map entries by local OID instead of scanning the whole map.
  - Consider invalidating from a pg_constraint syscache callback instead.
  - Check: a TAP test with 50 partitions and a DEBUG2 message per scan, asserting one scan per rebuild after ANALYZE.

### Issue 5: User documentation was not updated for parallel apply of non-streamed transactions
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/ref/create_subscription.sgml
- **Line(s)**: 343-361
- **Description**:
  - None of the 18 changed files is documentation.
  - create_subscription.sgml:343-353 still describes streaming=parallel as applying only streamed in-progress transactions.
  - logical-replication.sgml:2756-2761 and config.sgml:5797-5806 still say max_parallel_apply_workers_per_subscription controls parallelism "for streaming of in-progress transactions".
  - logical-replication.sgml:2734-2739 sizes workers with only "some reserve" for parallel apply workers.
  - Nothing documents:
    - that non-streamed transactions are now applied in parallel by default;
    - that commit order is preserved;
    - dependency tracking and its false positives;
    - the fallbacks for parallel-unsafe changes;
    - the 16MB limit and its suspended/resumed LOG messages;
    - permanent slot use (Issue 2).
  - Schedule and refutation do not apply.
  - **Evidence**: grep and view of the docs in the checkout.
- **Risk**: Operators under-size worker slots, cannot interpret the new behavior or log messages, and are surprised by a change that is on by default.
- **Suggested Fix**:
  - Update the streaming parameter, the GUC description, and the logical replication configuration and architecture sections.
  - Add a subsection on parallel apply.
  - Change the sizing guidance to: leaders + max_parallel_apply_workers_per_subscription × subscriptions + sync workers.
  - Validate with `make -C doc/src/sgml check`; no functional test is needed.

### Issue 6: find_frel_dependency runs redundant full dependency scans
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 1745-1794; 1623-1659; 1669-1698; 1481
- **Description**:
  - **Redundant scan**: Each loop iteration calls `find_all_dependencies_on_rel(X, FOREIGN_KEY or REFERENCED_KEY)`, a full iteration (1634). It then calls `check_and_record_rel_dependency(X)`, which calls `find_all_dependencies_on_rel(X, ALL_KEYS)` (1678). ALL_KEYS matches every kind (1642-1644), so the second scan covers everything the first one finds: the first doubles the cost and adds nothing.
  - **Misleading comment**: FOREIGN_KEY entries are keyed by the referenced table's remote ID (1481), so the first call in the refkeys loop rarely matches anything. The comment at 1741-1744 implies a behavior that call does not provide.
  - **Dead condition**: `if (schema_change)` at 1785 is always true, because of the return at 1773-1774.
  - Correctness is preserved through the ALL_KEYS scan.
  - **Schedule**: Any TRUNCATE or RELATION message for a table that has foreign keys.
  - **Classification**: Performance and readability.
  - **Evidence**: Code-trace.
- **Risk**: An extra full-table scan per related table, and a misleading comment.
- **Suggested Fix**:
  - Drop the kind-specific calls.
  - Remove the redundant condition.
  - Rewrite the comment.
  - The existing TRUNCATE/RELATION dependency cases in 050 serve as the regression test.

### Issue 7: Dependency diagnostics are hard to act on
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 1076-1079, 1101-1104, 1589, 1654-1655, 1695, 1832-1833, 858-859, 898-899, 1025-1026; applyparallelworker.c:1080-1081
- **Description**:
  - The DEBUG1 messages print publisher relation IDs (LogicalRepRelId) as "table %u", which cannot be resolved in the subscriber's pg_class. Foreign-key keys report the referenced table.
  - "for action %d" prints a raw enum value.
  - The suspend/resume LOG messages do not name the subscription, unlike other apply-worker LOG messages, and there is no stats counter.
  - "init relmap for %s" omits the schema and is logged per relation on every launch.
  - `get_dependency_type_str` returns a non-const `char *`.
  - The regexes in 050 (lines 375 and 425) depend on these message formats.
  - **Classification**: Observability.
  - **Evidence**: Code-trace.
- **Risk**: Slower diagnosis in production.
- **Suggested Fix**:
  - Print "remote relation %u (%s.%s)" or the local qualified name.
  - Print action names instead of numbers.
  - Include the subscription name in the LOG messages, with errdetail, and consider a stats counter.
  - Return `const char *`.
  - Update the 050 regexes to match.

### Issue 8: pa_wait_for_depended_transaction polls with pg_usleep and reports no wait event
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 2228-2286 (2280; comment 2264-2278)
- **Description**:
  - **When it polls**: The loop checks the shared hash every 1ms while the transaction it depends on has not been locked yet, or after that worker failed and left its entry behind (the code acknowledges this at 2264-2272).
  - **No wait event**: pg_stat_activity shows the process as active with no wait_event.
  - **No latch or postmaster-death check**: Exit relies on CHECK_FOR_INTERRUPTS after the leader sends SIGTERM. I did not trace whether the process can be orphaned if the leader dies without signaling it.
  - **Classification**: Hardening and observability.
  - **Evidence**: Code-trace.
- **Risk**: Waits that do not show up in monitoring, and a wait loop that does not follow the standard pattern.
- **Suggested Fix**:
  - Use `WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH, 1L, <new wait event>)` followed by `ResetLatch`.
  - Test: hold the depended-on worker before BEGIN with an injection point, and assert the waiting process's wait_event is not NULL.

### Issue 9: The dependency memory limit is approximate but documented as exact
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 654-658, 676-679, 865-867, 878-879, 1114, 1185-1231, 1267-1304, 1909
- **Description**:
  - **Contradictory comment**: "Kept exact by accounting the estimated entry size" contradicts itself.
  - **What is counted**: keysize counts only struct sizes and datum bytes. It ignores palloc chunk headers, power-of-two rounding across the 4+ncols allocations, and the hash bucket array (1909), which never shrinks.
  - **Effect**: Actual memory when the nominal 16MB limit trips can be a multiple of that, and it stays allocated afterwards.
  - **Off-by-one wording**: Line 656 says usage must fall "below half", but the code at 878-879 resumes at half or below, matching the comment at 865-867.
  - **No configuration**: The limit is hard-coded, has no GUC, and is not documented.
  - **Classification**: Documentation accuracy and memory accounting.
  - **Evidence**: Code-trace; not measured.
- **Risk**: Unexpected leader memory use and a tuning point that operators cannot see.
- **Suggested Fix**:
  - Reword the comments.
  - Use `GetMemoryChunkSpace()`, or a dedicated memory context with `MemoryContextMemAllocated()`.
  - Consider a GUC and document it.
  - Optionally recreate the table after it drains.

### Issue 10: Stale references, typos and misleading names
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 159-160, 167, 178, 180, 285-286, 2249, 2293, 2312-2321
- **Description**:
  - **applyparallelworker.c**:
    - Typos "identitied" (167), "Simiarly" (178), and "a insert_conflict" (180; the conflict type is insert_exists).
    - Heading underlines do not match the heading lengths (159-160, 285-286).
    - Line 2249 says the entry is removed only on commit, but `pa_commit_transaction` also runs after PREPARE (worker.c:3169-3170). So `pa_commit_transaction`, `pa_transaction_committed` (2293) and the "xid %u committed" message (2321) actually mean "finished applying".
  - **logicalrelation.h:59** refers to `check_dependency_on_rel`, which does not exist; the function is `check_and_record_rel_dependency`.
  - **worker.c**:
    - Typos "lastest" (1611) and "the give action" (1798).
    - Missing blank line after a declaration (931-932).
    - `replica_identity_table` and `ReplicaIdentityKey` now also hold unique and foreign keys, so the names are too narrow.
  - **050_parallel_apply.pl**:
    - The comments at 409 and 419 are swapped relative to the statements at 411 (`SET value = NULL`) and 422 (`SET value = 'test'`).
    - Typos "no to stop" (232, 384, 434, 485) and "publiser-side" (972).
    - Line 690 says "for the delete" above a streamed UPDATE/INSERT.
  - **032_subscribe_use_index.pl:664** has an unexplained "HACK:" comment.
  - **Classification**: Documentation and naming.
  - **Evidence**: grep and view.
- **Risk**: Misleads maintainers, and some test comments describe the wrong scenario.
- **Suggested Fix**:
  - Fix the typos and the stale reference.
  - Rename to `pa_finish_transaction` and `pa_transaction_finished`, or document that "committed" includes prepared transactions.
  - Correct the 050 comments, and explain or remove the HACK.
  - Run pgindent.
  - No functional test is needed.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: pending
- **Why**: Durability gap in flush reporting; must be fixed before commit.
- **How verified**: pending

### Issue 2
- **Status**: Open
- **What changed**: pending
- **Why**: Per-transaction launch churn, log flooding and slot starvation with default settings.
- **How verified**: pending

### Issue 3
- **Status**: Open
- **What changed**: pending
- **Why**: Leader CPU cost on every feedback call.
- **How verified**: pending

### Issue 4
- **Status**: Open
- **What changed**: pending
- **Why**: Unindexed catalog scans repeated per partition on invalidation.
- **How verified**: pending

### Issue 5
- **Status**: Open
- **What changed**: pending
- **Why**: User-visible default behavior is not documented.
- **How verified**: pending

### Issue 6
- **Status**: Open
- **What changed**: pending
- **Why**: Redundant scans and a misleading comment.
- **How verified**: pending

### Issue 7
- **Status**: Open
- **What changed**: pending
- **Why**: Diagnostics are hard to act on.
- **How verified**: pending

### Issue 8
- **Status**: Open
- **What changed**: pending
- **Why**: Non-standard wait loop with no wait event.
- **How verified**: pending

### Issue 9
- **Status**: Open
- **What changed**: pending
- **Why**: Memory accounting is inaccurate and documented as exact.
- **How verified**: pending

### Issue 10
- **Status**: Open
- **What changed**: pending
- **Why**: Stale references, typos and naming.
- **How verified**: pending