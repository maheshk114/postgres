---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 1
round: 1
timestamp: "2026-11-27T06:11:53Z"
outcome: "issues_found"
reviewer_model: "gpt-6.2-astra"
input_sha256: "d15d003b616cbc6bab203c0dc5ded68f9cfcfb778bc617109d3bd5d8b31a6fc9"
---

## Review Summary
- **Round**: 1
- **Theme**: Comprehensive review
- **Mode**: resolved-plan
- **Model**: gpt-6.2-astra
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-1-review-1-astra.md
- **Issues Found**: 26
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] **Correctness, security, and protocol:** Traced ordinary COMMIT, PREPARE, both prepared decisions, and STREAM ABORT through `src/backend/replication/logical/worker.c:2848–2934,3080–3325,3934–4036`, origin advancement in `origin.c:1335–1369`, and restart at `worker.c:7647–7649,7689–7725`. Also checked the table-owner switch and the boundary between publisher and private DSM messages.
- [x] **Architecture and conventions:** Compared the new FINISHED/reuse contract in `src/backend/replication/logical/applyparallelworker.c:549–584,810–824,2312–2321` with synchronous stream completion at `1680–1707,2027–2049`, session-lock ownership in `src/backend/storage/lmgr/lmgr.c:1202–1240`, and global worker-slot allocation in `src/backend/replication/logical/launcher.c:383–471`.
- [x] **Concurrency, errors, and boundaries:** Followed suspension, whole-transaction spooling, partial spooling, cancellation, and dependency delivery through `worker.c:838–900,2269–2321,3357–3428,4242–4308` and `applyparallelworker.c:969–1013,1553–1643`. Checked which waits have heavyweight-lock edges and which depend on a future queue message.
- [x] **Logic, data flow, and types:** Compared dependency-key construction in `worker.c:776–833,1243–1300,1383–1552,1934–1989` with `proto.c:846–864,906–951`, numeric equality/send functions, executor index enforcement, and actual RI trigger queries. Checked replica-mode trigger enablement, old-tuple availability, partition attribute numbering, and invalidated peer maps.
- [x] **Tests and assertions:** Inspected `src/test/subscription/t/050_parallel_apply.pl`, including binary keys, memory suspension, PREPARE, mutable triggers, unique indexes, and FK trigger selection; compared `015_stream.pl`, `023_twophase_stream.pl`, `032_subscribe_use_index.pl`, `033_run_as_table_owner.pl`, and `034_temporal.pl`. Several schedules below require stopping a worker **before the row operation**; the existing before-COMMIT point is not equivalent.
- [x] **Performance, observability, documentation, and compatibility:** Compared the serial dispatch path and unqualified `pg_constraint` scan with `doc/src/sgml/ref/create_subscription.sgml:340–374` and `doc/src/sgml/config.sgml:5796–5818`. Checked publisher feedback against `src/backend/access/transam/xact.c:1382–1439,1611–1617` and the slot restart floor in `src/backend/replication/logical/logical.c:628–653`.
- [ ] **Validation limitation:** The supplied evidence establishes clean application of all twelve patches and successful out-of-tree configuration with assertions, injection points, and TAP enabled. No compilation, TAP, crash-recovery, sanitizer, or benchmark results were supplied. The findings are source traces; the regression schedules below are proposed, not executed. The ordinary queue-timeout TODO, synchronous streamed completion itself, and conservative false dependencies are not counted as defects.

## Issues

### Issue 1: A streamed abort can move the restart LSN past a transaction that never committed locally
- **Severity**: Critical
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`
- **Line(s)**: `worker.c:3934–3999,4027–4036,7647–7649`; `applyparallelworker.c:1824–1863`
- **Description**: Hold ordinary transaction T before subscriber commit. On a second worker, stream an independent S far enough to write a local tuple, then roll S back on the publisher after T's publisher commit. STREAM ABORT has no predecessor barrier. `pa_stream_abort()` installs S's abort LSN before aborting; with a local XID, core `RecordTransactionAbort()` advances the shared replication origin. The new leader reads that origin on restart, not the leader's flush-mapping list.
- **Risk**: If apply stops after S advances the origin but before T commits, restart can omit T permanently. Not sending flush feedback for S does not prevent this failure. Core also advances the origin for an aborting subtransaction with an XID.
- **Suggested Fix**: Do not let a streamed abort publish restart progress beyond the completed prefix. Either order origin-bearing aborts or separate rollback from ordered progress advancement. Regression: hold T, observe origin progress across S's abort, restart apply while T is still uncommitted, and verify T's row is present exactly once. Include rollback to savepoint.

### Issue 2: Flush feedback can acknowledge a later no-WAL transaction across an undurable commit
- **Severity**: Critical
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `2908–2918,5831–5866,6258–6278,6299–6308`
- **Description**: Let T1 commit a write with subscriber `synchronous_commit=off` while local flush is behind it. Let T2 finish on another worker without writing WAL, for example because a replica-enabled BEFORE INSERT trigger returns NULL. `RecordTransactionCommit()` takes its no-XID/no-WAL exit without updating that backend's `XactLastCommitEnd`. T2 therefore can report zero or an older local LSN. The loop keeps scanning after unflushed T1, deletes T2's mapping, and reports T2's remote end as flushed.
- **Risk**: The publisher can advance `confirmed_flush_lsn` beyond T1. If the subscriber loses unflushed WAL, the publisher need not resend T1 even if the subscriber requests an earlier restart. A genuinely flushed PREPARE is not the counterexample: flushing its WAL also flushes preceding WAL.
- **Suggested Fix**: Collect completion/write positions independently, but advance flush and retire mappings only over a contiguous durable prefix. Regression: hold WAL flush behind T1, complete a no-WAL T2 on a different worker, and assert that subscriber feedback and publisher slot confirmation remain below T1 until its WAL is flushed.

### Issue 3: Safety classification can execute a column default as the wrong user and for the wrong operation
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `relation.c:722–749`; `worker.c:4690–4704,4919–4932,5599–5606,5644–5648`
- **Description**: On a cold safety cache, UPDATE, DELETE, and TRUNCATE inspect subscriber-only INSERT defaults. `contain_mutable_functions_after_planning()` is not a metadata-only operation: the planner can evaluate immutable calls with constant arguments (`clauses.c:5378–5490`). UPDATE and DELETE do this before `SwitchToUntrustedUser`; TRUNCATE does it before its owner-switching executor path.
- **Risk**: With `run_as_owner=false`, table-defined code can be invoked in the subscription owner's context. Even a benign default that raises an error can stop replication of a DELETE that would never evaluate that default under serial apply.
- **Suggested Fix**: Prefer conservative, nonexecuting classification; inspect only expressions relevant to the action. Where evaluation is unavoidable, establish the same identity as the executor first. Add a benign role/invocation regression to `033_run_as_table_owner.pl`: a cold-cache DELETE must not invoke an INSERT default under either role.

### Issue 4: Ordinary PREPARE releases a shared XID after the worker is already reusable
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`
- **Line(s)**: `worker.c:3164–3174`; `applyparallelworker.c:549–584,810–824,2246–2268,2312–2321`
- **Description**: W1 holds P's session-level apply lock; W2 is already asleep acquiring that lock. W1 prepares P and publishes FINISHED. Before its next statement, the leader can reuse W1 and replace `shared->xid` with Q. W1 then unlocks Q rather than P. Deleting P from the shared hash does not wake an existing lock-manager waiter.
- **Risk**: P's session lock can remain held for the pooled worker's lifetime, indefinitely stalling W2 and subsequent commits. Ordinary COMMIT uses the process-local remote XID and does not have this particular race.
- **Suggested Fix**: Unlock using `prepare_data.xid`, or make reuse impossible until all old lock ownership is discharged. Regression: gate W1 between FINISHED and unlock, assign Q with W2 already waiting on P, and verify W2 completes and P's apply lock disappears. Do not wait for COMMIT PREPARED merely to fix the handoff.

### Issue 5: Memory suspension fences ordinary BEGIN but not streamed replay
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `841–860,1918–1919,2784–2791,3362–3371,4248–4259`
- **Description**: Let an ordinary T exceed the dependency budget, then pause it before an unrecorded update changing key `a` to `b`. After T commits on the publisher, a genuinely streamed S updates `b`. Suspension makes the leader spool S. At STREAM COMMIT or STREAM PREPARE the leader replays S **before** its predecessor wait; row dependency checks return immediately because tracking is suspended. With T still before its update, the subscriber cannot find `b`.
- **Risk**: S can report `update_missing`, then commit in order without redoing the skipped update. The final row is wrong. `050_parallel_apply.pl:500–583` uses an ordinary follower, which takes the BEGIN fence.
- **Suggested Fix**: Fence the first untracked change, not just ordinary BEGIN. Cover full spool replay and later chunks of streams already assigned when suspension starts. Regression: force the schedule above, establish that S reached replay while T is held, and check the final value at `b`.

### Issue 6: Leader metadata discovery can wait forever on the worker it is still feeding
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1323–1357,1723–1740,2025–2042,2364–2378,5583–5606`
- **Description**: In one small ordinary publisher transaction, truncate `t`, change its replica identity to FULL, then insert into `t`. Let the assigned worker acquire `AccessExclusiveLock` for TRUNCATE before the leader processes the refreshed RELATION. Publisher command invalidations are replayed by `reorderbuffer.c:2530–2535`; pgoutput invalidates `schema_sent` and can emit RELATION before the insert. Processing it clears the leader map and opens `t` with `AccessShareLock`, which conflicts with its own worker's lock.
- **Risk**: The worker cannot release the lock without COMMIT; the leader cannot send COMMIT while blocked opening `t`. An ordinary worker waiting for queue input supplies no reverse heavyweight-lock edge. This can stall indefinitely with identical schemas and an empty send buffer.
- **Suggested Fix**: Avoid blocking metadata acquisition by a producer against its current consumer; use an ordered conservative fallback when metadata cannot be acquired. Regression: gate after the worker takes the truncate lock, deliver the second RELATION, and require bounded catch-up and the post-truncate row.

### Issue 7: An insert into a keyless table leaves no dependency for a later TRUNCATE
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1576–1605,1624–1699,2000–2023`
- **Description**: Warm the relation mappings. T1 first changes another table and later inserts into `t`, which has no replica identity or tracked unique/FK keys. Pause its worker before it reaches `t`. The leader records no footprint for that insert. T2 truncates `t`, takes `AccessExclusiveLock`, then waits for T1 at commit. T1 now needs `RowExclusiveLock` on `t`.
- **Risk**: Two serially valid transactions deadlock on an identical subscriber schema. The documented differing-schema warning does not cover this case.
- **Suggested Fix**: Record relation participation independently of row keys so a table-wide operation can find all prior writers without serializing unrelated inserts. Regression: run the schedule above and require no deadlock/restart and an empty final table.

### Issue 8: Waiting for an unsafe statement does not refresh its snapshot
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1834–1853,2175–2188,4503–4550`
- **Description**: Pause T1 after inserting a lookup row but before commit. T2 inserts into another table with a subscriber-only STABLE default that counts those rows. T2 pushes its statement snapshot, discovers the unsafe default, waits for T1, then evaluates the default under the same snapshot. A STABLE function can use the calling statement's active snapshot; the wait is not a new statement.
- **Risk**: The dependency wait and commit ordering both succeed, yet T2 permanently stores the old count.
- **Suggested Fix**: Establish the barrier before acquiring the execution snapshot, or restart the replication step with an appropriate fresh snapshot after waiting. Regression: use a STABLE lookup default and assert the stored count, not a DEBUG wait or total row count.

### Issue 9: An unsafe transaction does not fence later changes against its hidden writes
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1829–1853,1922–1990,2871–2889`
- **Description**: Publish UPDATE only on A and B. On both nodes an ENABLE ALWAYS row trigger on A inserts a B row; that INSERT is not published. T1 updates A, then T2 updates the resulting B row on the publisher. Pause subscriber T1 before its trigger inserts B. T2 sees no recorded B key for T1 and applies its B update immediately. The unsafe-action barrier only makes **T1** wait for its predecessors.
- **Risk**: T2 reports `update_missing`. T1 subsequently creates B and both commit in order, leaving B with T1's value instead of T2's. This does not require different schemas or a subscriber-side constraint violation.
- **Suggested Fix**: Give a transaction with unknown write effects an outgoing barrier as well as an incoming one, before later DML is allowed to execute. Regression: reproduce the UPDATE-only publication and compare the actual B value on both nodes.

### Issue 10: Streamed row actions bypass user-function safety even for an already committed publisher predecessor
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1804–1815,2282–2301,3577–3589,4269–4286`
- **Description**: Hold ordinary T1 after it writes a flag locally but before subscriber commit. Start S on the publisher **after T1's publisher commit** and force a stream chunk inserting into an unrelated table. A replica-enabled VOLATILE trigger there reads the flag into `NEW`. The stream's row keys do not intersect T1's, and `in_streamed_transaction` bypasses the safety check.
- **Risk**: S stores the old flag. Waiting at STREAM COMMIT cannot undo an already evaluated trigger. This is not the existing ambiguity about transactions that overlapped on the publisher.
- **Suggested Fix**: Apply the unsafe-effect barrier to streamed execution with respect to applicable already-dispatched predecessors. Regression: force S's trigger to run during a stream block while T1 is held, then compare the derived value with serial apply.

### Issue 11: Partition-root defaults run before the leaf safety check
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `1818–1825,4533–4555,5323–5337`
- **Description**: For non-TRUNCATE actions the classifier returns immediately on a partitioned root. INSERT evaluates `slot_fill_defaults()` on that root before routing the tuple and checking the leaf. With T1 held before commit and an ordinary T2 using a subscriber-only volatile lookup default on the root, the value is computed before any leaf wait.
- **Risk**: Even a leaf correctly classified unsafe receives an already incorrect datum; a default used for routing can also influence which partition is chosen.
- **Suggested Fix**: Check expressions actually evaluated on the root before filling defaults or routing, retaining separate leaf-trigger checks. Regression: replicate into a partitioned target with an inherited lookup default and verify the value in the leaf after releasing T1.

### Issue 12: Protocol bytes do not implement index or FK equality
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `776–833,1195–1226,1271–1300`
- **Description**: Use identical unconstrained-typmod `numeric PRIMARY KEY` tables with a warmed mapping and an existing `1.0`. Delay T1 before it deletes `1.0`; let T2 insert `1.00`. The wire values differ in text mode and the binary send format includes display scale. The numeric btree comparison considers them equal (`numeric.c:1146–1161,2425–2441`). The same raw comparator underlies local unique and FK keys irrespective of opclass, collation, or cross-type equality.
- **Risk**: T2 can see the still-committed old row and raise a unique conflict; serial delete-then-insert succeeds. Waiting until T1 has already deleted the row would hide the bug behind the index's own wait.
- **Suggested Fix**: Use equality/hash semantics compatible with the actual subscriber key, or a conservative dependency for keys where compatibility cannot be proved. Regression: exercise the numeric replacement in both transfer modes and require successful apply without retry.

### Issue 13: FK recording requires a replica-enabled trigger on the side that does not perform the check
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `relation.c:1045–1073,1207–1238`; `worker.c:1448–1549`
- **Description**: Warm both maps and enable only the subscriber child's actual FK INSERT check trigger for replica execution. Leave the parent's action triggers origin-only. T1 inserts a parent; T2 inserts its child. The parent skips recording the new key because **its own** PK-side triggers are disabled, although the child's enabled check needs that dependency.
- **Risk**: T2's lookup can fail before the parent is visible. Enabling both sides, as the new TAP case does, masks it; default-disabled FK triggers alone are not a reproduction.
- **Suggested Fix**: Derive producer-side recording from whether the corresponding consumer-side check/action can fire. Regression: enable the child INSERT trigger only, delay the parent insert, and require both rows with no FK error; test the converse delete direction independently.

### Issue 14: A new FK tuple can contain an unknown, unchanged TOAST value
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `worker.c:1269–1295,1448–1482,1935–1957,1983–1989`; `relation.c:1103–1123`
- **Description**: Give a child a separate integer replica identity and a composite FK `(grp, txt)`. Use externally stored text short enough to fit the parent's btree key. T1 inserts the parent `(newgrp, txt)`; T2 changes only the child's `grp`. The child need not send an old tuple, and its new `txt` can be `UNCHANGED`, with zero value bytes (`proto.c:846–864,906–934`). The ordered-key builder asserts those bytes exist. If an old tuple is sent, a non-identity NULL placeholder is not a usable replacement either.
- **Risk**: With the relevant subscriber RI triggers enabled, an assertion build can stop in the leader. A production build can miss the parent dependency and report an FK violation for a serially valid update.
- **Suggested Fix**: Distinguish unknown from actual NULL and use a compatible conservative key/barrier on both sides when a required value is unavailable. Regression: force external storage on the child, change the non-toasted component, hold the parent insert, and verify the child update.

### Issue 15: Constraint deferrability is not proof that the operation is checked at commit
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `849–866,1191–1205`
- **Description**: The unique-index filter skips every `!indimmediate` index. A `DEFERRABLE INITIALLY IMMEDIATE` unique constraint with its subscriber recheck trigger enabled can fail at `AfterTriggerEndQuery`. Delay deletion of `(id1,X)` before the delete and insert `(id2,X)` in T2. Separately, a `DEFERRABLE INITIALLY DEFERRED` FK can have an explicitly nondeferrable `ON DELETE RESTRICT` trigger (`tablecmds.c:14388–14414`). Delay the child deletion and let the next parent deletion reach that enabled subscriber trigger.
- **Risk**: Both schedules succeed serially but can fail before the commit-order barrier. Constraint-level catalog flags do not describe every trigger's timing.
- **Suggested Fix**: Track constraints with an applicable immediate check/action, using actual trigger timing and replica enablement or a conservative fallback. Add both schedules, enabling the specific subscriber recheck or RESTRICT trigger.

### Issue 16: Equality-only tracking omits exclusion conflicts and temporal FK coverage
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `relation.c:849–866,1095–1123,1239–1245`; `worker.c:1455–1482,1510–1549`
- **Description**: An immediate `EXCLUDE USING gist (period WITH &&)` index is not `indisunique`, but the executor enforces it on insert. Delay deletion of one interval, then insert an overlapping interval under a different RI. A PERIOD FK presents a second non-equality case: a parent `[1,10)` covers child `[2,5)`, but the two period values never have equal dependency keys. Core checks overlap and aggregate coverage (`ri_triggers.c:459–535`).
- **Risk**: The replacement interval can fail exclusion checking. With the actual temporal FK check enabled for replica execution, a child can fail before a covering parent is visible. Both schedules have a valid serial result.
- **Suggested Fix**: Use a relation-wide or proven equality-prefix dependency for unsupported exclusion/period predicates. Test overlapping replacement intervals and a strictly contained, non-equal child period following a held parent insert.

### Issue 17: FK discovery indexes a peer's invalidated attribute map using new catalog attnums
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `136–149,549–562,1095–1116,1259–1309`
- **Description**: Warm parent and child maps. Add a new trailing child column and an FK from it to an existing parent key locally, enabling the appropriate replica triggers. Process the next parent change before reopening the child. Relcache invalidation marks the child invalid but leaves its old `attrmap` allocated. `get_local_fkeys()` tests only for non-NULL, then indexes that old map at the new child attnum.
- **Risk**: This is an out-of-bounds read on a legitimate schema transition, not just outdated selectivity. It can produce an invalid dependency column or stop the apply process.
- **Suggested Fix**: Obtain a current, suitably locked peer map before using its attnums, or fall back conservatively until one exists; validate offsets against `maplen`. Regression: extend a previously cached child, touch the parent first, and exercise the lookup under a bounds assertion or sanitizer.

### Issue 18: TRUNCATE constructs a leaf map as though root and leaf had identical physical layouts
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `worker.c:5622–5646`; `relation.c:456–479,1609–1647`
- **Description**: On a worker's first operation against a partitioned target, TRUNCATE calls `logicalrep_partition_open(rel, childrel, NULL)`. NULL means copy the root map verbatim, not infer a leaf map. An attached leaf may have reordered columns or extra dropped physical attributes. `logicalrep_rel_mark_updatable()` immediately indexes the copied map using the **leaf** identity-key attnum.
- **Risk**: A leaf key beyond the root's `maplen` causes an out-of-bounds read during TRUNCATE itself. This does not rely on the incorrect map surviving a later truncate invalidation.
- **Suggested Fix**: Build the name-based root-to-child map, as the index-discovery path does, or avoid constructing a DML map to inspect TRUNCATE triggers. Regression: make TRUNCATE the first action on a cold worker with an attached leaf whose PK follows extra dropped attributes.

### Issue 19: A metadata-only publisher leaf is now validated as a real subscriber target
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `worker.c:1335–1353,1729–1740,2034–2042,4411–4429`; `relation.c:563–620`
- **Description**: With `publish_via_partition_root`, pgoutput sends RELATION for both ancestor and leaf, although the row change targets the ancestor (`pgoutput.c:757–791`). A compatible subscriber root may coexist with an unrelated, incompatible local table of the publisher leaf's name. `missing_ok` tolerates an absent leaf, but an existing one is passed to `logicalrep_rel_open()` and its columns are validated.
- **Risk**: A valid subscription can fail on every retry before applying its first root row, even with `streaming=off`. Previously, target validation was deliberately postponed until actual DML.
- **Suggested Fix**: Separate receipt of remote metadata from validation/opening of a local target. Regression: publish via root, create a same-named subscriber leaf decoy missing a published column, and verify that root DML replicates without touching the decoy.

### Issue 20: Replacing a trigger function does not invalidate cached parallel safety
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `122–192,681–709,749`
- **Description**: Warm a worker's safe classification for an immutable replica-enabled trigger function. Replace the routine with a VOLATILE implementation without changing the trigger or table. The safety cache watches relation invalidations only. A `pg_proc` change invalidates function caches, not the owning table's relcache entry (`inval.c:1475–1551`). The worker can execute the new implementation using the old classification.
- **Risk**: A subsequent ordinary row can read a preceding, still-uncommitted transaction too early, producing different stored data from serial apply. The stale classification can survive multiple transactions on a pooled worker.
- **Suggested Fix**: Invalidate safety results on relevant function/expression dependencies, or avoid caching them beyond a verifiable lifetime. Regression: reuse the warmed worker after replacing the function, hold a preceding lookup-table write, and verify the trigger-derived value.

### Issue 21: Trigger predicates and implicit defaults are missing from safety classification
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `relation.c:687–746`; `worker.c:2510–2545`
- **Description**: The classifier checks `tgfoid` but not the trigger's `WHEN` expression, which `TriggerEnabled()` evaluates separately. An immutable BEFORE trigger that suppresses a row can have a volatile predicate reading a preceding flag. Also, the classifier skips unmapped columns without `atthasdef`; the executor calls `build_column_default()` for them and can get an identity `NextValueExpr` or a type/domain default (`rewriteHandler.c:1277–1316`).
- **Risk**: T2 can insert a row that serial apply would suppress. Independently, two ordinary inserts with distinct published keys can receive subscriber-only identity values in reverse key order when T1 is delayed before its insert.
- **Suggested Fix**: Classify the actual predicates and effective defaults that the executor uses, without evaluating them during inspection. Test both a replica-enabled trigger with a mutable `WHEN` and a subscriber-only identity column with sequence cache one; assert the rows and key/value associations.

### Issue 22: Retained ordinary workers can starve table synchronization and defeat a lowered worker limit
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `applyparallelworker.c:529–537,688–704,867–899,1190–1214`; `worker.c:2884–2891,2912–2934`
- **Description**: Configure two logical worker slots and one parallel worker per subscription. Finish an ordinary parallel transaction, add a table to the existing publication, and refresh with copying. The idle parallel worker retains the last slot. `AllTablesyncsReady()` prevents further assignments, the idle worker does not retire, and launcher garbage collection only reclaims unattached slots. Similarly, after reloading the per-subscription maximum to zero, the reuse loop returns an existing worker before checking the new limit.
- **Risk**: The new table can remain unsynchronized indefinitely without a restart or intervention. A reload intended to stop parallel dispatch can leave ordinary transactions running in the pool.
- **Suggested Fix**: Reclaim idle workers on sync pressure and enforce the current cap before reuse. Document that ordinary transactions consume these slots too. Regressions: require the refreshed table to reach READY with two slots, and require no new parallel assignments after lowering the limit to zero.

### Issue 23: A streamed dependency-control send bypasses the existing spill fallback
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: `2059–2077,2282–2315,4269–4304,8429–8448`
- **Description**: For a streamed worker, the leader can send a dependency envelope immediately before a row or STREAM COMMIT. If that envelope is the first send to time out on a full queue, `send_internal_dependencies()` raises ERROR. The enclosing streamed path never reaches the fallback that would serialize the pending work. This occurs on the **streamed** path, independently of the acknowledged ordinary-message TODO.
- **Risk**: Transient backpressure that the existing streamed data path can handle instead restarts apply, or disables the subscription with `disable_on_error`.
- **Suggested Fix**: Propagate the control-send outcome to the streamed state machine and preserve the wait when switching to spill. Regression: force failure on the dependency envelope, rather than the following WAL message, then release the blocked worker and verify ordered replay without a restart.

### Issue 24: The public logical dispatcher accepts a worker-private message
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`
- **Line(s)**: `worker.c:5788–5797,6018–6036`; `applyparallelworker.c:1067–1107,1161–1188`
- **Description**: Publisher WALData and private DSM traffic enter the same logical dispatcher. Its internal-message case reaches the worker-control handler with only `Assert(am_parallel_apply_worker())` distinguishing the two contexts.
- **Risk**: An invalid public message that should receive a protocol error can trip an assertion or be interpreted as a local relation-map/dependency command in a production build. Normal pgoutput need not emit such a message for this to be a protocol-boundary defect.
- **Suggested Fix**: Dispatch private commands only from the DSM envelope branch and reject them at runtime on the public path. Add a negative dispatcher test that verifies protocol rejection without changing state.

### Issue 25: Explicitly serial subscriptions pay dependency decoding and catalog-scan costs
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`; `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: `worker.c:1888–1934,2348–2366,4503–4515`; `relation.c:1173–1186,1341–1389`
- **Description**: With `streaming=off` from startup, an ordinary change still enters `handle_dependency_on_change()` with an invalid new XID. It allocates tracking state, parses/copies row data, and looks up keys; the actual apply handler then parses the same row again. Rebuilding FK metadata scans all of `pg_constraint` with no scan key, once per inspected relation or leaf.
- **Risk**: Large tuples incur avoidable copying on the serial path, and cold or invalidated partition mappings multiply catalog work even when no parallel transaction can exist. This is a source-demonstrable cost, not a measured throughput claim.
- **Suggested Fix**: Add a fast path when no parallel work can be outstanding or assigned; keep dependency checking when a leader-applied change really can overlap a worker. Narrow FK discovery to relevant constraints. Regression: instrument the dependency path and verify that explicitly serial wide-row apply never enters it.

### Issue 26: Several TAP assertions can pass without exercising the claimed conflict or ordering
- **Severity**: Low
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl`
- **Line(s)**: `304–330,558–575,737–747,783–797,875–945,1115–1137,1274–1294`
- **Description**: The binary negative case releases T1 without establishing that the leader classified T3 while the dependency was live. The suspension case waits for a publisher-side echo **before** the UPDATE. The mutable trigger updates `id=1` only if that row does not exist, so the final count does not establish correct visibility. The expression-index case deletes `'updated conflict'` but inserts `'WOULD CONFLICT'`, which do not collide under `lower()`. The FK cases enable an unspecified `LIMIT 1` trigger rather than the event being tested.
- **Risk**: These cases can pass with the relevant overlap absent, the wrong visibility, no actual expression-index collision, or the applicable FK check disabled. Logs can demonstrate a conservative wait without demonstrating the promised data outcome.
- **Suggested Fix**: Synchronize on subscriber classification/execution while the predecessor is held, use genuinely conflicting values, select RI triggers by function/event, and assert derived values and exact rows. Verify each revised case would distinguish its intended incorrect behavior from serial apply.

## Resolution Log
_Updated by the driving agent as findings are addressed._

### Issue 1
- **Status**: Open
- **What changed**: Pending.
- **Why**: Stream-abort origin ordering is unresolved.
- **How verified**: Static abort/restart trace; regression not run.

### Issue 2
- **Status**: Open
- **What changed**: Pending.
- **Why**: Flush feedback does not enforce a durable prefix.
- **How verified**: Static feedback and no-WAL commit trace; regression not run.

### Issue 3
- **Status**: Open
- **What changed**: Pending.
- **Why**: Classification can evaluate expressions outside the executor's role and action.
- **How verified**: Static planner and role-switch trace; regression not run.

### Issue 4
- **Status**: Open
- **What changed**: Pending.
- **Why**: PREPARE ownership can change before unlock.
- **How verified**: Static worker-reuse and session-lock trace; regression not run.

### Issue 5
- **Status**: Open
- **What changed**: Pending.
- **Why**: Stream replay lacks a pre-apply suspension fence.
- **How verified**: Static spool and suspension trace; regression not run.

### Issue 6
- **Status**: Open
- **What changed**: Pending.
- **Why**: Metadata lookup can block its own message consumer.
- **How verified**: Static pgoutput, invalidation, queue, and relation-lock trace; regression not run.

### Issue 7
- **Status**: Open
- **What changed**: Pending.
- **Why**: A keyless writer is absent from the prior-writer scan.
- **How verified**: Static dependency and relation-lock trace; regression not run.

### Issue 8
- **Status**: Open
- **What changed**: Pending.
- **Why**: The pre-wait snapshot survives into expression execution.
- **How verified**: Static statement-snapshot and executor trace; regression not run.

### Issue 9
- **Status**: Open
- **What changed**: Pending.
- **Why**: Hidden trigger writes have no outgoing dependency.
- **How verified**: Static publication and worker-order trace; regression not run.

### Issue 10
- **Status**: Open
- **What changed**: Pending.
- **Why**: Streamed DML skips the unsafe-effect check.
- **How verified**: Static stream dispatch trace; regression not run.

### Issue 11
- **Status**: Open
- **What changed**: Pending.
- **Why**: Root defaults precede the leaf barrier.
- **How verified**: Static default and partition-routing trace; regression not run.

### Issue 12
- **Status**: Open
- **What changed**: Pending.
- **Why**: Wire equality and database equality differ.
- **How verified**: Static key comparison and numeric operator/send inspection; regression not run.

### Issue 13
- **Status**: Open
- **What changed**: Pending.
- **Why**: FK producer recording uses the wrong side's trigger enablement.
- **How verified**: Static FK discovery and RI-check trace; regression not run.

### Issue 14
- **Status**: Open
- **What changed**: Pending.
- **Why**: Unknown non-identity TOAST values have no safe dependency representation.
- **How verified**: Static tuple encoding/decoding and key-builder trace; regression not run.

### Issue 15
- **Status**: Open
- **What changed**: Pending.
- **Why**: Constraint filtering overlooks immediate checks.
- **How verified**: Static unique-recheck and FK-action timing inspection; regressions not run.

### Issue 16
- **Status**: Open
- **What changed**: Pending.
- **Why**: Overlap and coverage predicates are not represented.
- **How verified**: Static exclusion-index and temporal-RI trace; regressions not run.

### Issue 17
- **Status**: Open
- **What changed**: Pending.
- **Why**: Peer-map validity and bounds are not established.
- **How verified**: Static invalidation and indexing trace; sanitizer regression not run.

### Issue 18
- **Status**: Open
- **What changed**: Pending.
- **Why**: TRUNCATE supplies an identity conversion for potentially different row layouts.
- **How verified**: Static partition-map and identity-key trace; regression not run.

### Issue 19
- **Status**: Open
- **What changed**: Pending.
- **Why**: Metadata-only relations undergo target validation.
- **How verified**: Static ancestor/leaf protocol and subscriber-open trace; regression not run.

### Issue 20
- **Status**: Open
- **What changed**: Pending.
- **Why**: Function invalidation does not clear cached safety.
- **How verified**: Static cache registration and invalidation inspection; regression not run.

### Issue 21
- **Status**: Open
- **What changed**: Pending.
- **Why**: The classifier's expression set differs from the executor's.
- **How verified**: Static trigger predicate and effective-default inspection; regressions not run.

### Issue 22
- **Status**: Open
- **What changed**: Pending.
- **Why**: Idle worker retention does not handle sync pressure or a lowered cap.
- **How verified**: Static allocator, launcher, and tablesync trace; regressions not run.

### Issue 23
- **Status**: Open
- **What changed**: Pending.
- **Why**: A control-send timeout does not enter streamed fallback.
- **How verified**: Static queue-send and spill trace; regression not run.

### Issue 24
- **Status**: Open
- **What changed**: Pending.
- **Why**: The public/private distinction is assertion-only.
- **How verified**: Static inspection of both dispatcher entry paths; regression not run.

### Issue 25
- **Status**: Open
- **What changed**: Pending.
- **Why**: Dependency work is unconditional on the serial leader path.
- **How verified**: Static decoding and catalog-scan trace; no benchmark run.

### Issue 26
- **Status**: Open
- **What changed**: Pending.
- **Why**: Several test oracles do not distinguish the intended failure.
- **How verified**: Inspected TAP schedules, values, trigger selection, and assertions; TAP not run.

---

## Driver adjudication and final coverage

The original reviewer response above is unchanged. This section supersedes its
validation status, not its original observations or provenance.

**Overall High gate: BLOCKED.** Seven defects were independently reproduced.
Six of nine assignments yielded valid reviews; the broad-sweep, detailed-
correctness and polish specialist assignments still lack valid output after the
single permitted recovery cycle. No further reviewer retry was dispatched.
This is not a clean review or a merge recommendation.

### Frozen candidate and effective decision

- Scope: all twelve public Parallel Apply v28 patches and their interactions,
  explicitly selected by the engineer. Review only; no product fixes or posting.
- Separate checkout: `/home/maheshbehera/worktrees/postgresql-v28-review`.
  The original checkout was not modified.
- Base: `2af6dd3370677d8b06cf2a9eb62f69ba11e12cab`.
- Reviewed diff SHA-256:
  `f55b96e2ce17483b2bca7b123f44a2b80967f96a54794bad929f47f89fd646d6`.
  All first-patch preimages matched; all twelve patches applied cleanly.
  The fingerprint was checked again after runtime validation.
- Tier: **High**, driver estimate. Change size: 18 files, 5,579 additions and
  195 deletions. Qualitative complexity: cross-process state machines, locks,
  snapshots, durability, metadata invalidation, streaming, 2PC and dependency
  tracking. Concurrency and failure interactions justify this tier; no numerical
  language-specific complexity score was used.
- Primary model: `gpt-6-astra`.
- Model selection: capability guidance plus explicit human approval of Opus,
  Astra and Grok. The engineer subsequently requested `gemini-4-hydrogen`;
  it was added, not silently substituted. The earlier avoid-Gemini preference
  did not override this explicit instruction.
- Model access: signed-in Microsoft enterprise GitHub Copilot, authorized by the
  engineer; authenticated CLI route only, no direct vendor API. CLI 1.0.116 ACP
  catalog and configuration responses established enabled IDs and reasoning
  levels. Reviewer tools were restricted to read-only view/rg/glob, without yolo;
  this was not represented as an OS sandbox.
- Reasoning: Opus and Astra supported `low,medium,high,xhigh,max`, selected `max`.
  Grok and Hydrogen supported `low,medium,high,xhigh`, selected `xhigh`.
  Maximum reasoning was explicit per exact runtime identity.
- Capability references:
  https://platform.claude.com/docs/en/models/overview,
  https://openai.com/index/introducing-gpt-6-2-astra-sol/,
  https://docs.x.ai/developers/models.
  Hydrogen was the engineer's exact-model override.
- Bounds: 45 minutes per process group, 15-second kill grace. Five initial Opus
  timeouts consumed the one run-wide targeted recovery cycle. Recovery retained
  the model and maximum reasoning, with bounded reading instructions. Remaining
  follow-up allowance: **zero**.
- Placement: `Features/28` denotes patch version, not an ADO feature. No ADO task
  exists. `task-unknown` artifacts are retained for this explicitly authorized
  local-only review commit; they are not eligible for an ADO Software Factory
  PR gate. No task number was invented and nothing was pushed.

### Assignment coverage

All assignments inspected the same frozen source. Filenames below are relative
to `/home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/`.
Every filename starts with `task-unknown-attempt-1-`.

| Assignment | Exact runtime model | Reasoning | Final evidence suffix | Outcome |
|---|---|---|---|---|
| Broad sweep | claude-opus-5.5 | max | stage-attempt-2-review-1-opus.md | Failed: duplicated output sections |
| Architecture | claude-opus-5.5 | max | stage-attempt-1-review-2-opus.md | Issues found |
| Edge cases | claude-opus-5.5 | max | stage-attempt-2-review-3-opus.md | Issues found |
| Detailed correctness | claude-opus-5.5 | max | stage-attempt-2-review-4-opus.md | Failed: filtered/incomplete response |
| Testing | claude-opus-5.5 | max | stage-attempt-2-review-5-opus.md | Issues found |
| Polish/hardening | claude-opus-5.5 | max | stage-attempt-2-review-6-opus.md | Failed: duplicated output sections |
| Comprehensive | gpt-6.2-astra | max | stage-attempt-1-review-1-astra.md | Issues found |
| Comprehensive | grok-4.7 | xhigh | stage-attempt-1-review-1-grok.md | Issues found |
| Additional comprehensive | gemini-4-hydrogen | xhigh | stage-attempt-1-review-1-hydrogen.md | Issues found |

All fourteen attempt artifacts, including eight failures, are retained. The
failure reports' partial findings are preserved but do not count as signoff.
Input hashes and finalized receipts were checked. Successful reviewers' observed
assistant model identities matched their requested identities. An audit of tool
arguments found no reads targeting sibling reports or current-run evidence.
This audit is a bounded transport check, not a proof of model independence.

### Independently reproduced defects

| ID | Severity | Reachable schedule and observed result | Source anchors |
|---|---|---|---|
| V28-01 | Critical | Hold ordinary T before subscriber commit; stream and abort later S. Origin advances past T. Disable/re-enable apply while T remains uncommitted: T's publisher-committed row is permanently absent. | worker.c:3934-4036; applyparallelworker.c:1824-1863 |
| V28-02 | High | Exceed dependency memory with ordinary transactions, hold an untracked UPDATE, then replay a later spooled stream. `update_missing` is emitted; publisher ends at v2, subscriber at v1. | worker.c:841-860,1918-1919,4248-4259 |
| V28-03 | High | Hold a lookup INSERT before commit; a later subscriber-only STABLE default waits but retains its earlier snapshot. Stored count is 0, not 1. Serial control stores 1. | worker.c:1834-1853,4503-4550 |
| V28-04 | High | Update an unrelated column while a non-replica-identity FK column is unchanged external TOAST. The apply leader hits the key-builder assertion. This is demonstrated on an assertion-enabled build only. | worker.c:1269-1295,1448-1482 |
| V28-05 | High | Hold UPDATE of numeric PK 1.0 to 2 before execution; next transaction inserts 1.00. Bytewise keys miss numerical equality, producing a subscriber-only unique conflict. Serial control succeeds. | worker.c:776-833,1195-1226 |
| V28-06 | High | Enable only the child's actual FK triggers for replica execution. Hold parent INSERT; later child INSERT fails its FK check instead of waiting. Serial control succeeds. | relation.c:1045-1073,1207-1238; worker.c:1448-1549 |
| V28-07 | High | Identical schemas and UPDATE-only publication: A's trigger inserts B, but that INSERT is unpublished. Hold A's update; a later published B update overtakes the hidden insert and is skipped. Publisher value 2, subscriber value 1. Serial control stores 2. | worker.c:1829-1853,1922-1990,2871-2889 |

Source-anchor paths are under
`/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/`.
These are seven distinct failures, not a count of agreeing model reports.
No fixes were made. Their regression assertions deliberately pass when the
known defect is observed: **a PASS in a reproduction log does not mean safe code**.

### Validation and refutation

- Build/install passed with assertions, injection points and TAP enabled.
- Published `050_parallel_apply.pl`: 56 assertions passed.
- Six changed existing subscription tests: 117 assertions passed.
- Final custom harness: 12 scenarios, 15 assertions; seven reproduced defects,
  four correct serial controls and one negative/refutation probe.
- A cold TRUNCATE followed by INSERT and UPDATE through a reordered partition
  leaf produced the correct `99|v|m`. Grok's persistent-map-corruption schedule
  was not reproduced. Separate immediate out-of-bounds/dropped-column hypotheses
  remain unconfirmed, not disproved by that narrower probe.
- DELETE's search literal does not determine the old tuple's wire spelling.
  The numerical-equality reproduction instead changes the stored key 1.0 to 2
  and then inserts 1.00.
- `ENABLE ALWAYS TRIGGER ALL` is invalid syntax. Reproductions enable the actual
  named FK triggers through a catalog-driven DO block.
- No sanitizer, non-assertion build, crash-durability or performance result is
  claimed. The origin-loss case uses apply-worker restart, not an OS crash.

### Surviving unconfirmed candidates

The deduplicated ledger maps every numbered valid-review finding and the retained
failed-output findings to canonical groups:
`/home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/reproduction/adjudication.json`.
Only V28-01 through V28-07 are runtime-confirmed. In particular, premature flush
feedback across an undurable commit, the PREPARE shared-XID reuse race, and
leader/worker metadata-lock deadlocks remain important **unconfirmed** candidates.
Model agreement does not upgrade these to demonstrated failures. Performance,
test-gap and hygiene observations remain separate from confirmed product bugs.

### Durable reproduction material

Scripts, validation metadata, final TAP outputs, selected server-log excerpts and
provenance audit are committed under:
`/home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/reproduction/`.
Initial harness setup failures remain in session storage; they were not counted
as product failures.

To reproduce using a fresh out-of-tree assertion/injection-point build and
installed injection_points extension, set `V28_REPO` to this checkout,
`V28_BUILD` to the build directory, `V28_INSTALL` to its installation prefix and
`V28_ROOT` to a writable external output directory. Then run:

```bash
python3 /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/reproduction/run-v28-repros.py fresh \
  stream-abort-origin suspended-stream stable-default fk-toast numeric-key \
  one-sided-fk hidden-trigger-write stable-default-serial numeric-key-serial \
  one-sided-fk-serial hidden-trigger-write-serial partition-truncate
```

Use a new attempt name for each invocation. The runner refuses to reuse output
directories and returns nonzero if any scenario fails. Test clusters are isolated
and stopped by the PostgreSQL TAP harness; no existing PostgreSQL service is used.