---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 2
round: 3
timestamp: "2026-11-27T06:58:43Z"
outcome: "issues_found"
reviewer_model: "claude-opus-5.5"
input_sha256: "323f9a9be4152bab5acb47af0f7efe9e6270c8b9037221e003ad4f82738332db"
---

## Review Summary
- **Round**: 3
- **Theme**: Edge cases & robustness
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-2-review-3-opus.md
- **Issues Found**: 4
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Read the flush-tracking code: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c` lines 5819-5905 (`get_flush_position`, `store_flush_position`) and 6240-6300 (`send_feedback`). Also read `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c` lines 2133-2166 (`pa_get_last_commit_end`) and `pa_maybe_reuse_worker` (lines 549-585, via the supplied diff).
- [x] Read the commit paths in worker.c: 2841-2935 (`apply_handle_commit`, including the parallel worker's `last_commit_end = XactLastCommitEnd` at line 2914) and 4224-4352 (`apply_handle_stream_commit`). Used grep to locate line 4393 (`apply_handle_commit_internal` → `store_flush_position(..., XactLastCommitEnd, ...)`).
- [x] Read the suspension and dependency code in worker.c:
  - 780-960: `maybe_suspend_parallel_apply`, `maybe_resume_parallel_apply`
  - 1860-2010: `handle_dependency_on_change`
  - 2226-2420: `handle_streamed_transaction`, `handle_parallelized_transaction`
  - 2762-2826: `apply_handle_begin`
  - 8430-8512: `send_internal_dependencies`, `get_last_parallelized_xid`, `maintain_commit_order_dependency`
  - Grep anchors: 2072/2076 (the leader waits or sends dependencies), 4143 (`apply_spooled_messages` sets `in_remote_transaction`), 4506/4667/4897/5578 (DML handlers go through `handle_parallelized_transaction`).
- [x] Read applyparallelworker.c: 478-545 (`pa_can_start`), 1553-1605 (`pa_send_data`), 860-897 (`pa_free_worker`). Grep anchors: 753/762 (relmap send raises ERROR) and 2101 (a second relmap-send ERROR site). Used the supplied diff for `pa_launch_parallel_worker` and `pa_allocate_worker`.
- [x] Tests: read `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/015_stream.pl` lines 296-342. Grepped `debug_logical_replication_streaming = immediate` across `src/test/subscription/t`: it is set on the subscriber in 015, 018 and 023, and on the publisher in 016, 018, 019 and 023.
- [x] Candidates I ruled out by reading the code:
  - PARTIAL_SERIALIZE streams skipping dependency checks: refuted. The leader waits at worker.c:4298 before setting `FS_SERIALIZE_DONE` at 4303, so the worker replays the spool only after all predecessors commit.
  - NULL `entry->local_end` dereference in `pa_maybe_reuse_worker`: no reachable path found.
  - `FlushPosition` being freed while the hash still points to it: not possible, because the entry is removed from the hash before `pfree`.
  - Treated as not an issue: ordinary send-timeout TODOs, intentional false dependencies, and synchronous streaming completion.
- [x] Considered the driver's validation evidence (build; 050 with 56 assertions; 001/010/015/026/027/032 with 117 assertions). None of it runs the schedules described below.
- [x] Independence: I did not read `/home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews` or any review run directory. I used 20 of 20 tool calls.
- [ ] Runtime reproduction: not done, because this review is read-only and running commands is prohibited. **All findings are based on code tracing only.**
- [ ] Tests run by me: none.
- [ ] Areas not covered in this attempt:
  - `relation.c` dependency-key derivation: unique and foreign-key column mapping, partition attnum mapping, `logicalrep_rel_check_parallel_safety`.
  - Two-phase paths: `apply_handle_prepare` (worker.c:3058 and following), STREAM PREPARE (probably shares Issue 2's ordering, not re-read), and COMMIT/ROLLBACK PREPARED ordering.
  - The guard conditions in `pa_distribute_remote_rel_to_workers` (around applyparallelworker.c:2080-2105).
  - The `preceding_xid` wait at worker.c:1848.
  - DSA/dshash lifetime and cleanup on error.
  - The TRUNCATE dependency branch.
  - The body of `050_parallel_apply.pl`.
  - Protocol and serialization changes in `proto.c`.

## Issues

### Issue 1: Reported flush position can skip past a commit that is not yet durable (stale `local_end` plus flush advancing beyond the flushed prefix)
- **Severity**: Critical
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - worker.c 5829-5861: the loop; 5849-5853 advance `*flush` and delete the entry; the comment at 5856-5860 explains why the loop doesn't stop.
  - worker.c 2912-2914: a parallel worker's non-streamed commit copies `XactLastCommitEnd`.
  - worker.c 4318-4320: a parallel worker's streamed commit does the same.
  - worker.c 4393: the leader stores `XactLastCommitEnd`.
  - worker.c 6264-6277: `send_feedback` only keeps the value from moving backwards.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c` 2160: `pa_get_last_commit_end`.
- **Description**:
  - **The defect.** `get_flush_position` no longer stops at the first entry whose `local_end` is ahead of the local flush position. It keeps iterating and, for any *later* entry with `local_end <= local_flush`, sets `*flush = pos->remote_end` and deletes that entry. This is only safe if `local_end` increases along `lsn_mapping`, and it doesn't:
    - `local_end` comes from `XactLastCommitEnd`.
    - `RecordTransactionCommit` updates `XactLastCommitEnd` only when the transaction wrote a commit record or other WAL (the no-xid, no-WAL path jumps to `cleanup`).
    - So an applied transaction that writes no WAL reports its worker's or leader's *previous* commit end, or 0 for a new worker. That value can be far behind its predecessor's commit.
  - **Preconditions** (all defaults except the parallel subscription):
    - Subscription with `streaming = parallel` on a publisher that supports parallel apply.
    - Subscription `synchronous_commit = off` (the default), so apply commits are asynchronous.
    - `max_parallel_apply_workers_per_subscription >= 2`.
    - A remote transaction that commits on the subscriber without writing WAL. Examples: an `update_missing` or `delete_missing` conflict, or changes skipped because the table is not READY. In the leader path this also applies whenever the leader applies a transaction itself (pool full, suspended, or tablesync in progress).
  - **Minimal schedule**:
    1. Publisher runs T1: `INSERT INTO t VALUES (100)`. The leader sends it to W1, which commits asynchronously. The commit record end L1 is still in WAL buffers, so `local_flush < L1`.
    2. Publisher runs T2: `UPDATE t SET b = 1 WHERE a = 5`, where row 5 is missing on the subscriber. The key is independent, so it goes to W2. W2 waits for T1's transaction lock (commit order), then commits with no xid. Its `last_commit_end` is W2's previous commit end, or 0, which is below L1.
    3. The leader runs `send_feedback` → `get_flush_position`:
       - E1 (T1) is finished but `L1 > local_flush`, so it is kept.
       - E2 (T2) has a stale `local_end <= local_flush`, so `*flush = T2.end_lsn` and E2 is deleted.
       - The publisher's `confirmed_flush` moves past T1.
    4. The subscriber crashes before the WAL writer flushes L1. This can be an OS crash, an `immediate` stop, or any backend crash, since crash-restart discards unwritten WAL buffers.
  - **Observable result**: T1 is lost locally. The origin progress recovers to an older position, and the walsender forwards the restart LSN to `confirmed_flush`, so T1 is never resent. Row 100 is permanently missing on the subscriber, with no error.
  - **Why core guarantees don't prevent this**:
    - The commit-order wait covers only transaction-lock release (visibility), not WAL flush.
    - An asynchronous commit only calls `XLogSetAsyncXactLSN`.
    - The logical walsender treats the reported flush as `confirmed_flush` and skips anything before it on restart.
    - Before this patch, the loop returned at the first entry that wasn't flushed, so a stale `local_end` could only delay the flush position, never advance it.
  - **Classification**: durability or progress-tracking defect, not a conflict.
  - **Evidence**: code trace only; not reproduced at runtime.
- **Risk**: Silent, permanent loss of committed publisher transactions on the subscriber after a crash, in the default configuration. Advancing past a predecessor's commit is a frequent event (every no-WAL transaction that follows an unflushed parallel commit), which makes the vulnerable window recurring.
- **Suggested Fix**:
  - Advance `*flush` and delete entries only over the contiguous prefix of finished and flushed entries. After the first entry that is unfinished or has `local_end > local_flush`, keep iterating only to collect `local_end` and `committed_xids` and to update `*write`.
  - Optionally, also make no-WAL commits report a monotonic value (for example, take the maximum with the predecessor's `local_end`).
  - **Regression test** (TAP, for example in 050):
    1. Subscriber settings: `wal_writer_delay = 10s`, `bgwriter_lru_maxpages = 0`, `checkpoint_timeout = 1h`.
    2. Delete row a=5 locally on the subscriber.
    3. On the publisher, run T1 (`INSERT 100`) and then T2 (`UPDATE ... WHERE a = 5`), and record the publisher LSN.
    4. Poll `pg_replication_slots.confirmed_flush_lsn` on the publisher until it is at or past that LSN.
    5. Run `$node_subscriber->stop('immediate')`, start it again, and wait for catch-up.
    6. Assert that `count(*) WHERE a = 100` is 1.
  - An `Assert` in `get_flush_position` that `*flush` never passes a retained entry would also catch this deterministically.

### Issue 2: While parallel apply is suspended, dependency checks are skipped entirely, so leader-replayed spooled streams and already-assigned streams apply out of dependency order
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**:
  - worker.c 841-864: `maybe_suspend_parallel_apply` returns true for as long as suspension lasts.
  - worker.c 1918-1919: early return before the dependency checks and before the wait or send at 2072/2076.
  - worker.c 2283-2289: the stream `TRANS_LEADER_SEND_TO_PARALLEL` path calls `handle_dependency_on_change`.
  - worker.c 2361-2365: the `TRANS_LEADER_APPLY` path calls `handle_dependency_on_change`.
  - worker.c 4246-4257: replay at 4252 happens *before* the commit-order wait at 4255.
  - worker.c 4143: replay runs with `in_remote_transaction` set.
  - worker.c 2789-2790: the upfront wait exists only for non-streamed BEGIN.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c` 490-491: suspension makes new streams leader-serialized.
- **Description**:
  - **The defect.** Once `parallel_apply_suspended` is set, `handle_dependency_on_change` returns before doing *any* dependency lookup. The only compensating waits are:
    - the one-time wait for the transaction that triggered suspension (856), and
    - the upfront wait at non-streamed BEGIN and BEGIN PREPARE.
  - Two paths have no compensation:
    - **(a) Leader-serialized streams.** At STREAM COMMIT, the `TRANS_LEADER_APPLY` branch replays the spool. Each replayed change goes through `handle_parallelized_transaction` → `handle_dependency_on_change(..., NULL)`, which returns early. The leader therefore applies every change before waiting for predecessors at 4255.
    - **(b) Streams assigned to a worker before suspension.** Later chunks reach 2289, which also returns early, so no `PA_MSG_XACT_DEPENDENCY` is sent. The only wait is commit order at STREAM COMMIT (4279).
  - **Preconditions**: `streaming = parallel`; dependency-tracking memory reaches the 16MB limit (for example, large REPLICA IDENTITY FULL values as in 050, or many in-flight keys); a publisher transaction large enough to be streamed overlaps an in-flight parallelized transaction that touches the same key.
  - **Minimal schedule for (a)**:
    1. Y1, a large RI-FULL insert, goes to W1, which is still applying (in a test, hold it at `parallel-worker-before-commit`).
    2. Y2 is `INSERT t(k=1, 'orig')`. Its first change triggers suspension, and W2 is told to wait for Y1 *before* inserting.
    3. X starts on the publisher after Y2 commits and runs `UPDATE t SET v = 'x' WHERE k = 1` plus enough data to be streamed. Its STREAM START arrives while suspended, so it is `TRANS_LEADER_SERIALIZE`.
    4. At STREAM COMMIT, the leader replays the UPDATE, finds no row, logs an `update_missing` conflict and skips it, then waits for Y2 and commits.
  - **Variant (b)**: X's STREAM START is assigned to W3 before Y1/Y2. After suspension, the chunk containing the UPDATE is sent to W3 with no dependency, so W3 applies it before W2's INSERT.
  - **Observable result**: the subscriber keeps `'orig'` while the publisher has `'x'`, a permanent silent divergence. DELETE behaves the same way (`delete_missing`, row survives). An INSERT after a DELETE of the same key in a predecessor raises a unique-violation ERROR.
  - **Why core guarantees don't prevent this**:
    - Replica-identity lookups use a dirty snapshot and `XactLockTableWait` only for tuples already written. W2 hasn't written the row yet because it is blocked in its dependency wait.
    - The RowExclusiveLock taken by INSERT and UPDATE are compatible, and there is no tuple to lock.
    - The commit-order wait happens only at commit.
    - Replica-role trigger rules play no part here.
  - **Classification**: a data conflict that occurs only under parallel apply. It is not a genuine schema conflict, because serial apply would see the row.
  - **Evidence**: code trace only; not reproduced at runtime.
- **Risk**: Silent data divergence, or spurious apply errors and restarts, exactly when the system is under memory pressure from large transactions, which is when streaming is most likely.
- **Suggested Fix**:
  - While suspended, wait before applying instead of skipping checks:
    - **(a)** In the `TRANS_LEADER_APPLY` branches of STREAM COMMIT and STREAM PREPARE, call `maintain_commit_order_dependency(NULL)` *before* `apply_spooled_messages` when `parallel_apply_suspended` is set. Alternatively, make the suspended path of `handle_dependency_on_change` do a one-time `maintain_commit_order_dependency(winfo)`.
    - **(b)** On suspension, send a single commit-order dependency on the last parallelized xid to every in-progress streaming worker. Alternatively, keep lookup-only checks while suspended; they allocate no tracking memory.
  - **Regression test**: extend the suspension block in 050.
    1. With W1 held at the injection point, run Y2 (`INSERT k = 1`).
    2. Run a streamed X that updates `k = 1`. Use publisher `debug_logical_replication_streaming = immediate` or a small `logical_decoding_work_mem`.
    3. Release the injection point and wait for catch-up.
    4. Assert that the subscriber value is `'x'` and that no `update_missing` appears in the subscriber log.
    5. Add a second case where X's first chunk is sent before suspension.

### Issue 3: With `debug_logical_replication_streaming = immediate` on the subscriber, every non-streamed transaction, and the relmap bootstrap of each new worker, hits a hard ERROR and the apply worker restarts in a loop
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**:
  - applyparallelworker.c 1565-1566: `pa_send_data` returns false in immediate mode without attempting to send.
  - applyparallelworker.c 478-537: `pa_can_start` has no immediate-mode check.
  - applyparallelworker.c 753-762: relmap send raises ERROR.
  - applyparallelworker.c 887-895: a worker with `serialize_changes` set is stopped.
  - applyparallelworker.c around 2101: a second relmap-send ERROR site; I did not read its guard conditions.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c` 2776 and 2796-2808: BEGIN → ERROR.
  - worker.c 8443-8446: `send_internal_dependencies` → ERROR.
  - `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/015_stream.pl` 303-336.
- **Description**:
  - **Preconditions**: `streaming = parallel`, and the subscriber sets `debug_logical_replication_streaming = immediate`, a documented mode where the leader serializes all changes to files.
  - **Schedule 1 (non-streamed)**:
    1. Any small transaction arrives and BEGIN calls `pa_allocate_worker`. `pa_can_start` returns true.
    2. The action is `TRANS_LEADER_SEND_TO_PARALLEL`, and `pa_send_data` returns false immediately.
    3. ERROR "could not send data to the logical replication parallel apply worker". The apply worker restarts, receives the same BEGIN again, and loops forever, so replication stalls.
  - **Schedule 2 (streamed)**:
    1. Each stream switches to partial serialization, which sets `serialize_changes`. At the end, `pa_free_worker` stops that worker.
    2. The next stream launches a fresh worker. The leader's relmap is non-empty, so the send at 759-762 raises ERROR and the apply worker restarts.
    3. Each restart makes progress by only one stream.
  - **Compared with before the patch**: non-streamed transactions were applied by the leader, and immediate mode worked for streams.
  - **Why the passing test doesn't cover this**: after enabling immediate mode, 015 issues only one streamed INSERT and no non-streamed transaction. 018 and 023 also set the mode on the publisher, so their transactions are streamed.
  - **Distinct from the timeout TODO**: no queue timeout is involved. The failure is deterministic.
  - **Classification**: an error that occurs only under parallel apply, not a schema conflict.
  - **Evidence**: code trace only; not reproduced at runtime.
- **Risk**: The documented debug or testing mode wedges replication or causes repeated ERRORs and restarts. Developer tests that rely on it can hang or pass only by masking the error through restarts.
- **Suggested Fix**:
  - Make `pa_can_start` (or the BEGIN and BEGIN PREPARE allocation) return false for non-streamed transactions in immediate mode, so the leader applies them.
  - Let control messages (relmap bootstrap, dependency lists) bypass the immediate-mode early return, for example with a `force` flag or a separate helper, or write them to the spool.
  - **Regression test**: in 015, after the immediate-mode block, add one small non-streamed INSERT and two more streamed transactions. Wait for catch-up, assert the row counts, and assert that the subscriber log has no "could not send" errors.

### Issue 4: The quick pool-full check uses `==`, so it never fires after `max_parallel_apply_workers_per_subscription` is lowered below the current pool size
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 702-704 (`list_length(ParallelApplyWorkerPool) == max_parallel_apply_workers_per_subscription`)
- **Description**:
  - **Preconditions**: the pool has grown to N workers, and then `max_parallel_apply_workers_per_subscription` is lowered below N with a SIGHUP reload. Workers that handled non-streamed transactions stay in the pool. The only stop site I read is `pa_free_worker`, which is on the streaming path.
  - **Schedule**: while every pool worker is busy, each new transaction does `pa_setup_dsm` (DSM create and dshash attach) and scans the worker array under `LogicalRepWorkerLock`. `logicalrep_worker_launch` then refuses because `nparallelapplyworkers >= max`, and `pa_free_worker_info` tears everything down.
  - **Observable result**: wasted DSM create/destroy cycles and lock traffic on every such transaction. That is exactly the overhead the new check was meant to avoid. This is a performance issue only; I found no correctness impact.
  - **Evidence**: code trace only.
- **Risk**: Unnecessary overhead and DSM churn under load after a configuration change.
- **Suggested Fix**: Use `>=`. Optionally, trim idle pool workers above the new limit when reusing workers. **Regression test**: optional, because it is hard to observe. One option is a DEBUG message, counted after a reload that lowers the limit.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 2
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 3
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 4
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending