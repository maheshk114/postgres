---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 1
round: 1
timestamp: "2026-11-27T06:17:07Z"
outcome: "issues_found"
reviewer_model: "grok-4.7"
input_sha256: "de79ced7f3406a82c20821e2ba7a653f6dcd958900ce4c279d897e479bd9a9c8"
---

## Review Summary
- **Round**: 1
- **Theme**: Comprehensive review
- **Mode**: resolved-plan
- **Model**: grok-4.7
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-1-review-1-grok.md
- **Issues Found**: 2
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] Dimension 1 correctness: traced non-streaming dispatch, commit-order waits, and partition apply in `src/backend/replication/logical/worker.c` (`handle_parallelized_transaction` 2346, `apply_handle_tuple_routing` 5250, `apply_handle_truncate` 5560) and `src/backend/replication/logical/relation.c` (`logicalrep_partition_open` 1534).
- [x] Dimension 2 architecture: NULL `map` means "same attribute order as the root" (`relation.c` 1612-1643). Unique/FK collectors honor that (`relation.c` 971-976 and 1377-1382). The new truncate caller does not (`worker.c` 5644).
- [x] Dimension 3 concurrency: worker partmap is process-local. Leader dependency scan (`worker.c` 2012-2024, `find_frel_dependency` 1724) does not populate the worker cache. `logicalrep_partmap_invalidate_cb` (`relation.c` 1408-1456) clears `localrelvalid` but the next truncate reinstalls the bad map. Pool reuse keeps that map for the worker lifetime (`launcher.c` default `max_parallel_apply_workers_per_subscription` = 2).
- [x] Dimension 4 data flow: `slot_modify_data` (`worker.c` 2662-2687, call at 5429) indexes `part_entry->attrmap` against the leaf tupdesc. Early return at `relation.c` 1564-1568 ignores a later correct routing map.
- [x] Dimension 5 tests: `src/test/subscription/t/050_parallel_apply.pl` covers reordered leaf columns for unique tracking (987-1020) and volatile trigger functions (749-790). It never truncates that leaf and then updates, and it never uses an immutable trigger function with a mutable WHEN clause. No TAP run was supplied; tests were not executed.
- [x] Dimension 6 docs/compat: series comments document unique/FK false positives and commit-order waits (`applyparallelworker.c` header). They do not mention this attrmap lifetime or WHEN volatility. Replica-role trigger firing was checked in `src/backend/commands/trigger.c` 3566-3616.
- [x] Refuted, not reported: toasted replica-identity UNCHANGED false negative. `heap_update` logs the old key when `id_has_external` (`src/backend/access/heap/heapam.c` 4115-4117); the subscriber copies UNCHANGED values from that old tuple (`worker.c` 1918-1935).
- [ ] Not promoted: streaming dependency skip, 2PC prepare releasing `parallelized_txns`, and `pa_maybe_reuse_worker` NULL `local_end`. Not shown to be parallel-only failures against publisher locks, serial apply, or the leader send-before-reuse window. Documented unique-key false positives and default-replica FK non-firing are accepted limitations.

## Issues

### Issue 1: TRUNCATE installs a root attrmap on a reordered leaf and later UPDATEs write the wrong columns
- **Severity**: High
- **File**: src/backend/replication/logical/worker.c
- **Line(s)**: 5644-5645
- **Description**: `apply_handle_truncate` calls `logicalrep_partition_open(rel, childrel, NULL)` only so it can run `check_relation_parallel_apply_safety`. A NULL map copies the root attrmap (`relation.c` 1637-1643) and sets `localrelvalid` (`relation.c` 1664). That map is root-local attnum to remote attnum. The leaf tupdesc can use a different physical order. A later `logicalrep_partition_open` with the executor's root-to-child map returns the cached entry and does not rebuild (`relation.c` 1564-1568). `slot_modify_data` (`worker.c` 2682-2687, called at 5429) then applies remote values through that map onto the leaf tupdesc. INSERT and DELETE search slots are converted by the executor map and are not corrupted; UPDATE is. The leader's truncate dependency scan opens partitions with `build_attrmap_by_name_if_req` (`relation.c` 971-976) in the leader process only. A parallel worker has its own partmap. `handle_parallelized_transaction` returns false for the worker (`worker.c` 2354-2355), so the worker executes the NULL open. Reachable without `publish_via_partition_root` when the subscriber relation is partitioned and the publisher truncate names that root, which is the layout already in `050_parallel_apply.pl` (publisher `regress_part_tab`, leaf `regress_part_tab_1` ordered `value, marker, id`, replica identity FULL).
- **Risk**: Wrong committed subscriber data, or an apply error that stops the subscription. With replica identity FULL, `logicalrep_rel_mark_updatable` still marks the leaf updatable, so apply succeeds. Example after a poisoned open: remote columns `(id, value, marker)`, leaf physical order `(value, marker, id)`. `UPDATE` of `id` to 99 writes `'99'` into `value` and leaves `id` unchanged. `UPDATE` of `marker` to a non-integer calls `int4in` on the leaf `id` column and errors. The bad entry survives worker reuse until relcache invalidation. With one parallel worker this is deterministic.
- **Suggested Fix**: Build the root-to-child map with `build_attrmap_by_name_if_req(RelationGetDescr(rel->localrel), RelationGetDescr(childrel), false)` and pass it, as `logicalrep_build_dependent_unique_indexes` does. Do not cache a partition entry from a NULL map unless the tupdescs match by position. Regression: in `050_parallel_apply.pl`, set `max_parallel_apply_workers_per_subscription=1`, use the existing reordered leaf, `TRUNCATE` before any DML on a fresh worker (wait on `parallel-worker-before-commit`), `INSERT (1, 'v', 'm')`, `UPDATE` `id` to 99, and assert `id, value, marker` is `99, v, m`.

### Issue 2: Parallel-safety ignores a mutable trigger WHEN clause
- **Severity**: Medium
- **File**: src/backend/replication/logical/relation.c
- **Line(s)**: 692-721
- **Description**: `logicalrep_rel_check_parallel_safety` marks an action unsafe only from `func_volatile(trigger->tgfoid)` (line 707), after skipping internal and origin-only triggers. It never inspects `trigger->tgqual`. `TriggerEnabled` evaluates WHEN with `ExecQual` before calling the trigger function (`src/backend/commands/trigger.c` 3566-3616). A WHEN clause may call a stable or volatile function; CREATE TRIGGER only rejects direct references to other relations, not function bodies that read tables. If the trigger function is immutable, `parallel_global_unsafe[action]` stays false, and `check_relation_parallel_apply_safety` does not wait for `preceding_xid` (`worker.c` 1829-1849). Defaults and generated expressions are checked with `contain_mutable_functions_after_planning` (lines 724-746). WHEN is not. Index expressions and CHECK constraints are immutable by PostgreSQL rules and are not this bug.
- **Risk**: A replica or always trigger can fire or be skipped against a state serial apply would not see, and a BEFORE trigger that returns NULL can drop the change. Schedule: subscriber `saw_row()` is STABLE and returns whether `other` contains id 1; BEFORE INSERT trigger function is IMMUTABLE and returns NULL; trigger is `ENABLE REPLICA` with `WHEN (saw_row())`. TX-1 inserts into `other` and pauses before commit in a parallel worker. TX-2 inserts into the target table. Parallel apply evaluates WHEN before TX-1 commits, does not fire the trigger, and inserts the row. Serial apply commits TX-1 first, WHEN is true, the trigger returns NULL, and the row is not inserted. `050_parallel_apply.pl` 749-790 only covers a volatile trigger function.
- **Suggested Fix**: For each replica/always user trigger with `tgqual`, `stringToNode` it and run `contain_mutable_functions`. If mutable, set `parallel_global_unsafe` for every event in `tgtype`, same as a mutable trigger function. Add a TAP case with an immutable trigger function, a stable WHEN that reads a second table, and the pause-before-commit schedule above. Assert the second insert waits and matches serial apply.

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