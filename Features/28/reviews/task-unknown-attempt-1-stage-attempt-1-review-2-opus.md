---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 1
round: 2
timestamp: "2026-11-27T06:23:32Z"
outcome: "issues_found"
reviewer_model: "claude-opus-5.5"
input_sha256: "b620d9a504de3d39779c191ab912b69cf8d524d739ec3beac4cfbcb7cbc3cb6f"
---

## Review Summary
- **Round**: 2
- **Theme**: Architecture & patterns
- **Mode**: resolved-plan
- **Model**: claude-opus-5.5
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-1-review-2-opus.md
- **Issues Found**: 12
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Flush accounting. I traced `get_flush_position` and `store_flush_position` (/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c:5818-5902) against the `send_feedback` clamp (6262-6277), the parallel worker commit path (2901-2919), `apply_handle_commit_internal` (4354-4404) and `apply_handle_rollback_prepared` (3267-3329). I also checked `RecordTransactionCommit` in /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/access/transam/xact.c:1438-1439 and 1611-1612, and the `pa_get_last_commit_end` comment (applyparallelworker.c:2118-2161).
- [x] Suspension and resume. I read `maybe_suspend_parallel_apply` and `maybe_resume_parallel_apply` (worker.c:836-901) and the early return in `handle_dependency_on_change` (1912-1919). I followed every caller: the streamed path at 2289, `handle_parallelized_transaction` at 2346-2391, spooled replay at 4096-4150, stream commit at 4244-4256 and stream prepare at 3361-3370. I compared these with the suspension checks in BEGIN and BEGIN PREPARE (2783-2791, 2972-2980) and with test coverage in 050_parallel_apply.pl:503-582.
- [x] Key equality. I read the hash and compare functions (worker.c:776-831), the key builders (1160-1236), `get_unique_indexes` (relation.c:833-933) and how the UPDATE path copies UNCHANGED columns (worker.c:1936-1957).
- [x] Foreign keys. I read `fkey_trigger_enabled_in_replica` (relation.c:1045-1070), the gate in `get_local_fkeys` (1196-1300) and `check_and_record_fkey_dependency` (worker.c:1444-1556). I checked those against RI trigger placement and the replica-role rules.
- [x] Parallel safety. I read `check_relation_parallel_apply_safety` (worker.c:1805-1854), `logicalrep_rel_check_parallel_safety` (relation.c:660-750), and where stream start sets `in_streamed_transaction` (worker.c:3569) for every apply action.
- [x] Sending to workers. I read `pa_send_data`, `pa_switch_to_partial_serialize`, `pa_launch_parallel_worker` and `pa_distribute_remote_rel_to_workers` (applyparallelworker.c:1553-1645, 679-765, 2056-2102), plus `send_internal_dependencies` and `maintain_commit_order_dependency` (worker.c:8429-8513).
- [x] Debug GUC usage. I checked how the subscriber-side `debug_logical_replication_streaming` is documented (/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/config.sgml:13564-13574) and used in 015, 016, 018, 019 and 023 TAP tests.
- [x] Defaults and docs. I checked the default in subscriptioncmds.c:192, the worker setting at worker.c:7533-7547, and create_subscription.sgml:341-353. The conventions check covered worker_internal.h:268-290, logicalrelation.h:55-60 and relation.c:1174-1177.
- [ ] Build and TAP execution. Not done: this reviewer has read-only tools, and no runtime output was supplied. None of the findings has been reproduced at runtime.
- [ ] Full cross-check of the internal relation writer and reader in proto.c, and line-by-line review of partition column-map routing. Only partially reviewed.
- [ ] Effect of Issue 1 on `retain_dead_tuples` advancement (worker.c:6641-6665). Unconfirmed.

## Issues

### Issue 1: `get_flush_position` can confirm a later transaction as flushed while an earlier async commit is still unflushed
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c (also applyparallelworker.c, xact.c)
- **Line(s)**: worker.c 5818-5862, 2901-2919, 4369-4395, 3305-3317, 6262-6277; applyparallelworker.c 2118-2161; xact.c 1438-1439, 1611-1612
- **Description**:
  - **What changed**: Base PostgreSQL stopped at the first entry with `local_end > local_flush`. The new loop keeps going so it can collect later parallel transactions. For any later entry with `local_end <= local_flush` it sets `*flush = pos->remote_end` and deletes the entry, even when an earlier entry is still unflushed. That is only safe if `local_end` values increase in list order, and they don't:
    - A transaction that is empty on the subscriber has no xid, so `RecordTransactionCommit` takes the `goto cleanup` at xact.c:1439. That skips `XactLastCommitEnd = XactLastRecEnd` at 1612.
    - The worker therefore publishes a stale value from its own previous transaction (`MyParallelShared->last_commit_end = XactLastCommitEnd`), or 0 if it is that worker's first transaction. The leader-applied path (4393) does the same with the leader's stale value.
    - ROLLBACK PREPARED with no matching gxact stores `InvalidXLogRecPtr` and writes no WAL (3305-3317).
  - **When it can happen**: Subscription `synchronous_commit` defaults to off. Empty transactions are common:
    - update_missing or delete_missing conflicts;
    - a published table the subscriber hasn't refreshed (UNKNOWN state);
    - tables that are not yet READY.
  - **Schedule**:
    1. A (insert) is dispatched to W1 and commits asynchronously, unflushed.
    2. B (an UPDATE of a row missing on the subscriber) runs on W2. It waits only for A's commit, not its flush, then finishes with a stale `local_end`.
    3. At the next feedback, A stays in the list but B is removed and `flush = B.remote_end` is sent. The clamp at 6276-6277 only prevents going backwards.
    4. The publisher moves `confirmed_flush` past A.
    5. The subscriber crashes or stops with `stop -m immediate` before the WAL writer flushes A.
  - **Failure**: A's commit is lost locally and never resent, because `CreateDecodingContext` jumps ahead to `confirmed_flush`. This is silent permanent data loss.
  - **Refutation attempts**: PREPARE, COMMIT PREPARED and a found ROLLBACK PREPARED all flush, so they are safe. A non-empty B always has a commit record after A's, so ordering holds there.
  - **Unconfirmed side effect**: the same over-reported value feeds `last_flushpos` in `maybe_advance_nonremovable_xid` (6647-6658).
  - The comment at applyparallelworker.c:2121-2123 ("InvalidXLogRecPtr if the transaction wrote no changes") is wrong: the value is stale, not invalid.
  - **Regression test**:
    1. Set `wal_writer_delay=10s` on the subscriber (keep `synchronous_commit=off`).
    2. Run A = INSERT, then B = UPDATE of a key absent on the subscriber.
    3. Poll until the publisher's `confirmed_flush_lsn` is at or past B's commit LSN, then `stop('immediate')`, restart, catch up, and assert A's row exists.
- **Risk**: Committed publisher transactions can be silently lost on the subscriber after a crash.
- **Suggested Fix**:
  - Advance `*flush` and delete entries only while every earlier entry is flushed. Keep scanning afterwards only to collect `local_end`, `committed_xids` and `*write`.
  - Alternatively, clamp each entry's `local_end` to at least its predecessor's.
  - Fix the comment.

### Issue 2: While suspended, streamed transactions apply changes without waiting for transactions dispatched before the suspension
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c
- **Line(s)**: 836-866, 1912-1919, 2280-2290, 2358-2364, 4244-4256, 3361-3370, 2783-2791, 2972-2980; test 050_parallel_apply.pl 503-582
- **Description**:
  - **The gap**: Once `parallel_apply_suspended` is set, `handle_dependency_on_change` returns before any lookup (1918), for every caller. The "wait for everything" rule is enforced only in two places:
    - for the one transaction whose change triggered suspension (`maintain_commit_order_dependency(winfo)`, 855);
    - at BEGIN and BEGIN PREPARE of leader-applied non-streamed transactions (2789, 2978).
  - Two streamed paths have no equivalent:
    - **(a)** A streamed transaction S already assigned to W_S before suspension. Its later chunks go through line 2289, return early, and are sent with no dependency message.
    - **(b)** A streamed transaction S′ that the leader serialized (for example because `pa_can_start()` is false while suspended). At STREAM COMMIT or STREAM PREPARE the leader runs `apply_spooled_messages()` first, and each change returns early via 2363. It calls `maintain_commit_order_dependency(NULL)` only after the replay (4255, 3369).
  - **When it can happen**: Suspension fires precisely when workers lag and many keys are recorded (16MB, line 658). A transaction X dispatched before the suspension can still be running. Resume is blocked while the last parallelized transaction is in flight (888-893).
  - **Schedule** (variant b):
    1. X, a large non-streamed transaction, crosses the limit, and its tail includes `UPDATE t SET id=5 WHERE id=0`. W_X is still on the prefix.
    2. S′ commits on the publisher after X and contains `UPDATE t SET v='s' WHERE id=5`.
    3. S′ is streamed and serialized. At STREAM COMMIT the leader replays its changes with no wait. `FindReplTupleInLocalRel` uses a dirty snapshot, but id=5 doesn't exist yet, so the change is logged as update_missing and skipped.
    4. The leader then waits for X and commits S′.
  - **Failure**: The subscriber silently diverges (id=5 lacks S′'s update). A delete_missing gives the same result. An INSERT racing a not-yet-executed DELETE gives an insert_exists ERROR, and a held row lock gives a deadlock ERROR.
  - **Refutation attempts**:
    - Row locks protect only once X has executed the conflicting change.
    - `check_relation_parallel_apply_safety` waits only for parallel-unsafe relations.
    - The 050 suspension test covers only a non-streamed Tx-3.
  - **Regression test**: Extend 050 lines 503-582.
    1. Hold Tx-2 at `apply-update-before-open-indices`, with Tx-2 running `UPDATE ... SET id=5 WHERE id=0`.
    2. Detach the point.
    3. Run a streamed S′ on the publisher (`logical_decoding_work_mem=64kB`) that does a bulk insert and then `UPDATE ... WHERE id=5`.
    4. Wake Tx-2 and assert the final value equals S′'s value.
- **Risk**: Silent data divergence under load, which is exactly when suspension is likely.
- **Suggested Fix**: While suspended, make streamed paths wait as BEGIN does:
  - before the spooled replay at stream commit and stream prepare, call `maintain_commit_order_dependency(NULL)`;
  - for chunks of streamed transactions already assigned to a worker, send a dependency on the last parallelized transaction (once per chunk, or on the first change after suspension).

### Issue 3: Dependency keys compare publisher wire bytes, not subscriber equality
- **Severity**: High
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c (also relation.c)
- **Line(s)**: worker.c 776-831, 1160-1236 (and the by-attnum builder after it); relation.c 833-933; applyparallelworker.c 252-256 (rationale comment)
- **Description**:
  - **The problem**: Keys are `hash_any` and `memcmp` over the text or binary representation. `get_unique_indexes` ignores opclass and collation. Values that are equal to the index but differ in bytes therefore never match:
    - numeric `1.0` vs `1.00`
    - citext, or a nondeterministic ICU collation (`'Bob'` vs `'bob'`)
    - float `-0` vs `0`
    - publisher/subscriber type mismatch (text `'01'` → int)
    - cross-type FKs in binary mode (int8 FK referencing an int4 PK)
  - **Schedule**:
    1. Numeric PK on both sides. TX-1: `UPDATE t SET k=2 WHERE k=1.0` (or a large prefix followed by `DELETE k=1.0`). TX-2: `INSERT k=1.00`. This is valid on the publisher.
    2. On the subscriber no dependency is found, and W2 inserts while 1.0 still exists.
  - **Failure**: A unique violation (insert_exists) ERROR that serial apply would not raise. If TX-1 is consistently slower, the restart replays the same race, so the failure is a deterministic ERROR loop with no serial fallback.
  - **Refutation attempts**: Old keys from UPDATE/DELETE use stored values, so same-row RI tracking holds. The miss is on the INSERT side and the unique-key side. The header comment's claim that restarting "using the latest index information" recovers does not apply here.
  - **Regression test**: The numeric case above, with Tx-1 held at `apply-update-before-open-indices`. Assert no ERROR and the final row set. Optionally add a nondeterministic-collation variant.
- **Risk**: Replication can stall permanently on legitimate workloads with case-insensitive keys or keys with varying numeric scale.
- **Suggested Fix**: Build keys from subscriber-typed datums and hash and compare them with the index opclass and collation. Alternatively, fall back to table-level dependency when any key column's equality isn't bytewise (non-deterministic collation, or a type or opclass not known to be bytewise-equal).

### Issue 4: Streamed changes skip the parallel-safety wait even though earlier non-streamed transactions are now asynchronous
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c (also relation.c)
- **Line(s)**: worker.c 1805-1854 (early return 1809-1811), 3569, 2280-2290; relation.c 660-750
- **Description**:
  - **What changed**: In base, every transaction received before a streamed chunk was committed before the chunk was dispatched. The leader applied non-streamed transactions synchronously and waited at STREAM COMMIT.
  - With v28, a non-streamed X can still be running while later chunks of S, which on the publisher were written after X committed, run on W_S. `check_relation_parallel_apply_safety` returns early whenever `in_streamed_transaction` is set, which stream start does in the parallel worker too (3569). The leader does only row, unique and FK lookups.
  - **Schedule**:
    1. The subscriber has an `ENABLE ALWAYS` BEFORE INSERT trigger on `orders` that copies `products.price`.
    2. X: `UPDATE products SET price=20` is dispatched, but its commit is waiting on a slow predecessor.
    3. S, a streamed transaction committed after X, does `INSERT INTO orders`. W_S runs the trigger and reads price=10.
  - **Failure**: Derived data differs from serial and base apply. A trigger that validates existence instead raises an ERROR.
  - This is a v28 regression, distinct from the anomaly base already accepted (S seeing too much of transactions concurrent with it).
  - **Regression test**: The schedule above, using `parallel-worker-before-commit` on the predecessor and three workers. Assert `orders.price = 20`.
- **Risk**: Wrong trigger or default results for streamed transactions, which the non-streamed design explicitly protects against.
- **Suggested Fix**: For streamed transactions whose target relation is parallel-unsafe, have the leader send a dependency on the last parallelized transaction (once per chunk, or once per relation). Alternatively, run the safety check in the worker against a per-chunk preceding xid.

### Issue 5: FK dependency collection is gated on each table's own RI triggers
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c (also worker.c)
- **Line(s)**: relation.c 1045-1070, 1230-1235; worker.c 1444-1556; 050_parallel_apply.pl 1116-1137
- **Description**:
  - **Recording vs. lookup**: For insert-insert, the referenced-key entry is recorded only if the PK table's action triggers fire in replica mode (`local_refkeys`). The lookup and the violating check live on the FK table (`local_fkeys`). Delete-delete is the reverse. With triggers enabled on only one side, one half of the pair is missing.
    - **Case A**: superuser runs `ALTER TABLE fk ENABLE ALWAYS TRIGGER ALL`. TX-1 does `INSERT pk(1)`, TX-2 does `INSERT fk(1)`. Nothing is recorded, so TX-2 can run first and hit an FK violation ERROR.
    - **Case B**: only the PK table's triggers are enabled. TX-1 does `DELETE fk(1)` and TX-2 does `DELETE pk(1)`. If TX-2 runs before TX-1's delete, it gets a violation, or a deadlock with CASCADE.
  - **Reachability**: Under replica role these triggers fire only when explicitly enabled. One-sided enablement is a plausible configuration, and 050 always enables both sides.
  - The comment "Keep only PK-side action triggers" is also inaccurate for the FK-side call.
  - **Regression test**: Case A with only the fk table enabled, and TX-1 held at `parallel-worker-before-commit` behind a large prefix.
- **Risk**: Parallel-only FK errors and restart loops.
- **Suggested Fix**: Decide whether to track using the trigger that actually raises the error (FK-side check triggers for insert-insert, PK-side action triggers for delete-delete), and apply that decision to both the recording side and the lookup side.

### Issue 6: New control messages in streamed mode ERROR instead of falling back to partial serialization
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c (also applyparallelworker.c)
- **Line(s)**: worker.c 8429-8450, 2280-2290, 2066-2074, 855, 4269-4285, 3391-3412; applyparallelworker.c 1553-1612
- **Description**:
  - **What changed**: Base streamed apply switches to PARTIAL_SERIALIZE when `pa_send_data` times out (about 9s). v28 sends `PA_MSG_XACT_DEPENDENCY` on the same queue before the change, at stream commit and stream prepare, and at suspension. `send_internal_dependencies` raises an ERROR on timeout.
  - **Schedule**:
    1. Non-streamed A on W1 is blocked by a local row lock.
    2. Streamed B on W2 repeatedly touches A's keys, so W2 waits and its 16MB queue fills.
    3. The next dependency send times out, which raises an ERROR and restarts the leader. This repeats while the lock persists.
  - Base would have spilled gracefully. This is distinct from the acknowledged non-streamed TODO. `pa_distribute_remote_rel_to_workers` (2093-2099) is a TODO-marked sibling and is included only as context.
  - **Regression test**: A local session holds a row lock that blocks A. A large streamed B touches A's row and then many more rows. Assert the "will serialize the remaining changes" LOG appears and no ERROR.
- **Risk**: The worker restarts instead of degrading gracefully, which is a regression from base streamed behaviour.
- **Suggested Fix**: Have `send_internal_dependencies` return `bool`. In streamed callers, call `pa_switch_to_partial_serialize()` on failure. The PARTIAL_SERIALIZE commit and prepare paths already wait via `maintain_commit_order_dependency(NULL)`.

### Issue 7: `debug_logical_replication_streaming=immediate` on the subscriber deterministically breaks non-streamed transactions
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c (also worker.c, config.sgml)
- **Line(s)**: applyparallelworker.c 1561-1566, 744-760, 2093-2099; worker.c 2796-2812, 8384-8420; config.sgml 13564-13574
- **Description**:
  - **The problem**: In immediate mode `pa_send_data` always returns false. Non-streamed dispatch has no serialize path. Either the relation-info send in `pa_launch_parallel_worker` or the BEGIN send raises an ERROR. The leader restarts, the transaction is resent, and the same ERROR repeats indefinitely.
  - The documented contract says this GUC makes the leader serialize changes to files.
  - Existing TAP tests (015, 016, 018, 019, 023) use the GUC only with streamed traffic, so they don't hit this.
  - This is not the timeout TODO itself: the trigger is configuration-driven and deterministic.
  - **Regression test**: Set immediate on the subscriber, replicate one small transaction, and assert it arrives.
- **Risk**: Permanent stall for a documented developer setting. It also blocks the obvious way to test the fallback paths.
- **Suggested Fix**: In immediate mode, don't parallelize non-streamed transactions (have `pa_can_start` return false when not streaming), or route them to the leader. Update the GUC documentation.

### Issue 8: Non-streamed parallel apply is silently enabled by the default `streaming=parallel`, and user docs are not updated
- **Severity**: Medium
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/commands/subscriptioncmds.c (also worker.c, docs, applyparallelworker.c)
- **Line(s)**: subscriptioncmds.c 192; worker.c 7533-7547; create_subscription.sgml 341-353; config.sgml 5804-5808; applyparallelworker.c 393-401
- **Description**:
  - Every default subscription gains asynchronous non-streamed apply, dependency tracking, suspension and user-function waits, with no separate opt-out. Setting `max_parallel_apply_workers_per_subscription=0` also disables streamed parallelism.
  - The user docs still describe parallel apply as streaming-only. None of these is documented:
    - the commit-order guarantee;
    - the trigger and function safety rules;
    - the FK and unique tracking limits;
    - the memory suspension.
  - The `ParallelApplyTxnHash` comment still says "streaming transactions".
- **Risk**: Behaviour changes on upgrade that users can't discover, and there is no way to opt out selectively.
- **Suggested Fix**: Add a separate subscription option, or at least document the new behaviour and its limitations in create_subscription.sgml and logical-replication.sgml. Update the stale comments.

### Issue 9: Layering and convention deviations
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/include/replication/worker_internal.h (also logicalrelation.h, relation.c, worker.c, applyparallelworker.c)
- **Line(s)**: worker_internal.h 290; applyparallelworker.c 467, 717-719; logicalrelation.h 55-60; relation.c 1174-1177; worker.c 776-2075
- **Description**:
  - `extern bool parallel_apply_suspended;` lacks `PGDLLIMPORT`, unlike every other extern variable in that header (268-288). It is defined in applyparallelworker.c but driven from worker.c.
  - logicalrelation.h refers to a nonexistent `check_dependency_on_rel` (the real function is `check_and_record_rel_dependency`).
  - About 1,300 lines of dependency engine live in worker.c rather than in their own module.
  - `get_local_fkeys` does an unindexed full scan of `pg_constraint` per relation (`systable_beginscan(..., InvalidOid, ...)`) instead of using the conrelid and confrelid indexes.
  - The pool quick-check uses `==` rather than `>=`, so it misses the case where the GUC was lowered below the current pool size.
- **Risk**: Maintainability, extension or Windows linkage, and catalog-scan cost when there are many constraints.
- **Suggested Fix**: Add `PGDLLIMPORT`, fix the reference, move dependency tracking into its own file, use indexed scans (or `RelationGetFKeyList` plus a referencing lookup), and use `>=`.

### Issue 10: `pa_wait_for_depended_transaction` polls in a 1ms sleep loop
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 2228-2285
- **Description**: When the dshash entry persists (the transaction errored, or hasn't reached BEGIN), the function loops lock → unlock → `pg_usleep(1000)` with no latch wait. That burns CPU and responds to signals late until the leader restarts the workers.
- **Risk**: CPU spin during failure windows.
- **Suggested Fix**: Use `WaitLatch` with a timeout and a wait event, or a condition variable signalled from `pa_commit_transaction`.

### Issue 11: Fragile raw pointer from the transaction hash into `lsn_mapping` (hardening, unconfirmed)
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c
- **Line(s)**: 549-585, 2104-2116
- **Description**: `ParallelApplyWorkerEntry.local_end` points into a `FlushPosition` node that has a separate lifetime. `pa_maybe_reuse_worker` writes through `*entry->local_end` without a NULL check. I found no reachable path where the pointer is NULL or dangling: commit and prepare bind it, and streamed entries are removed by `pa_free_worker`. The invariant is implicit, though.
- **Risk**: A future change could cause a NULL or dangling write.
- **Suggested Fix**: Add an Assert or NULL guard, or key the flush node by xid instead of a raw pointer.

### Issue 12: Code hygiene and comment accuracy
- **Severity**: Low
- **File**: /home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c (also worker.c, relation.c)
- **Line(s)**: applyparallelworker.c 159-160, 167, 178, 283-284, 1106, 1828-1829, 2335-2343; worker.c 1611, 1798, 2819-2821; relation.c 297-336, 851-856
- **Description**:
  - `Assert(!dshash_find(...) && ...)` calls a lock-taking function inside an assert.
  - `found` in `pa_add_parallelized_transaction` is unused.
  - The `*_valid=false` writes after the memset in `logicalrep_relmap_update` are redundant.
  - The deferrable-unique comment claims a commit-time check, but the recheck trigger doesn't fire under replica role. The conclusion is still correct.
  - Typos: "identitied", "Simiarly", "lastest", "give action".
  - Section underlines have the wrong length.
  - There is a triple blank line.
  - The errmsg format string is `"\"(%d)\""`.
- **Risk**: Readability and pgindent/translation noise.
- **Suggested Fix**: Clean these up in the same series.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 2
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 3
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 4
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 5
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 6
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 7
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 8
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 9
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 10
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 11
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified

### Issue 12
- **Status**: Open
- **What changed**: pending
- **Why**: review-only run
- **How verified**: not yet verified