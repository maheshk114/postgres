---
producer: "review-code"
schema_version: 1
tier: "High"
contract: "direct"
execution_backend: "copilot-cli"
attempt: 1
stage_attempt: 1
round: 1
timestamp: "2026-11-27T06:09:18Z"
outcome: "issues_found"
reviewer_model: "gemini-4-hydrogen"
input_sha256: "c7b8ff39fd4ee8fd330066d1eb11068b7fe2b063ca1b82f93154eb408e9537fa"
---

## Review Summary
- **Round**: 1
- **Theme**: Comprehensive review
- **Mode**: resolved-plan
- **Model**: gemini-4-hydrogen
- **Artifact**: /home/maheshbehera/worktrees/postgresql-v28-review/Features/28/reviews/task-unknown-attempt-1-stage-attempt-1-review-1-hydrogen.md
- **Issues Found**: 12
- **Verdict**: ISSUES_FOUND

## Evidence Checklist
- [x] **Dimension 1 (Broad correctness, security, and spec conformance)**: Traced non-streaming/streaming/2PC dispatch, origin progress, `skiplsn`, `replica_identity_table` equality semantics, and snapshot isolation across `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`, `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`, and `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`. Found divergence and correctness bugs in Issues 1–8.
- [x] **Dimension 2 (Architecture, patterns, and repository conventions)**: Verified worker pool reuse (`pa_maybe_reuse_worker`, `pa_free_worker`), internal protocol framing (`LOGICAL_REP_MSG_INTERNAL_MESSAGE`, `PAWorkerMsgType`, `StaticAssertDecl` vs `PqReplMsg_WALData`), wait event registration in `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/utils/activity/wait_event_names.txt`, LWLock tranche registration in `/home/maheshbehera/worktrees/postgresql-v28-review/src/include/storage/lwlocklist.h`, and typedef additions in `/home/maheshbehera/worktrees/postgresql-v28-review/src/tools/pgindent/typedefs.list`.
- [x] **Dimension 3 (Robustness, errors, boundary conditions, and concurrency)**: Audited `dsa_create`/`dsa_pin`/`before_shmem_exit` lifetime in `applyparallelworker.c`, session locks and deadlock graph (`LockApplyTransactionForSession`), `shm_mq` timeout behavior (`send_internal_dependencies` in `handle_streamed_transaction`), concurrent `skiplsn` invalidation (`apply_handle_begin`), and unlocked `pg_inherits`/`pg_attribute` lookups (`get_local_fkeys`, `logicalrep_map_attnums_by_name`).
- [x] **Dimension 4 (Detailed logic, data flow, and type safety)**: Audited `build_replica_identity_key`, `build_replica_identity_key_by_attnums`, `ExtractReplicaIdentity` (`src/backend/access/heap/heapam.c:4115,9357`), `logicalrep_write_tuple` (`src/backend/replication/logical/proto.c:838`), `ri_triggers.c` (`RI_FKey_check`, `ri_FastPathCheck`, `ri_PerformCheck`), `execIndexing.c`, `constraint.c` (`unique_key_recheck`), `trigger.c` (`AfterTriggerEndQuery`, `EnableDisableTrigger`), and `snapmgr.c` (`GetTransactionSnapshot`).
- [x] **Dimension 5 (Tests, coverage, mocks, and assertions)**: Inspected `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/meson.build`, `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl`, and adjusted TAP tests (`001_rep_changes.pl`, `010_truncate.pl`, `015_stream.pl`, `026_stats.pl`, `027_nosuperuser.pl`, `032_subscribe_use_index.pl`); identified non-deterministic `LIMIT 1` trigger selection in `050_parallel_apply.pl` and missing coverage for the bugs reported below.
- [x] **Dimension 6 (Performance, observability, documentation, and compatibility)**: Inspected `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/config.sgml`, `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/logical-replication.sgml`, and `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/ref/create_subscription.sgml`; noted stale documentation for `streaming = parallel` / `max_parallel_apply_workers_per_subscription` and default `max_logical_replication_workers = 4` sizing impact.
- [ ] **Runtime build/test execution**: Read-only review per instructions; no compilation, linter, or TAP test execution was performed (`pg_ctl`, `meson`, and `prove` were not run), so runtime validation remains pending from the driver.

## Issues

### Issue 1: Spooled streaming commits/prepares execute before waiting on suspended in-flight parallel transactions
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 3366–3372 (`apply_handle_stream_prepare`), 4252–4257 (`apply_handle_stream_commit`), 1918–1920 (`handle_dependency_on_change`)
- **Description**:
  In `apply_handle_stream_commit()` and `apply_handle_stream_prepare()` under `case TRANS_LEADER_APPLY`, the leader calls `apply_spooled_messages()` before `maintain_commit_order_dependency(NULL)`. Inside `apply_spooled_messages()`, each spooled message goes through `apply_dispatch()` -> `handle_parallelized_transaction()` -> `handle_dependency_on_change(action, s, InvalidTransactionId, NULL)`. When `parallel_apply_suspended` is `true`, `maybe_suspend_parallel_apply(NULL)` immediately returns `true` at line 1918, causing `handle_dependency_on_change()` to return without checking any dependencies.
  - **Schema/Config**: Default `logical_decoding_work_mem = 64MB`, `streaming = parallel`, `max_parallel_apply_workers_per_subscription = 2`; table `t (id int, val text)` with `REPLICA IDENTITY FULL` (containing row `(0, 'idle')`) and an auxiliary table `bulk (x text)` for triggering streaming.
  - **Schedule**:
    1. `TX-1` (non-streamed): `INSERT INTO t VALUES (1, repeat('p', 10MB));` -> dispatched to `W1` (held before commit); `dependency_mem_usage` ≈ 10 MB.
    2. `TX-2` (non-streamed): `BEGIN; INSERT INTO t VALUES (2, repeat('t', 7MB)); UPDATE t SET val = 'v1' WHERE id = 0; COMMIT;` -> `INSERT` exceeds the 16 MB `PARALLEL_DEPENDENCY_MEMORY_LIMIT`, so `UPDATE (id=0)` sets `parallel_apply_suspended = true` and skips recording `id = 0` in `replica_identity_table`. `TX-2`'s `COMMIT` is sent to `W2`, which has not yet applied `UPDATE (id=0)`.
    3. `TX-3` (streamed, > 64 MB): `BEGIN; INSERT INTO bulk ...; UPDATE t SET val = 'v2' WHERE id = 0; COMMIT;` -> `STREAM START` sees `parallel_apply_suspended == true`, so `TX-3` is serialized (`TRANS_LEADER_SERIALIZE`). At `STREAM COMMIT` (while `W2` is still executing `TX-2`), leader runs `apply_spooled_messages()` first.
  - **Consequence**: `TX-3` executes `UPDATE t SET val = 'v2' WHERE id = 0` before `W2` executes `TX-2`'s unrecorded `UPDATE`. `FindReplTupleInLocalRel()` fails to find `(0, 'v1')`, logs `update_missing`, and drops `TX-3`'s update (or `delete_missing` drops a delete if `TX-2` inserted a row after hitting 16 MB and `TX-3` deleted it). Leader then waits at `maintain_commit_order_dependency(NULL)` and commits `TX-3`. Result: permanent **silent data divergence** with no error. In serial apply, `TX-2` commits before `TX-3` begins.
  - **Attempted refutation**: `apply_handle_stream_start()` checks `pa_can_start()` and selects `TRANS_LEADER_SERIALIZE`, which never calls `maintain_commit_order_dependency(NULL)`. Inside `apply_spooled_messages()`, `handle_dependency_on_change()` exits at line 1918 before inspecting any keys whenever `parallel_apply_suspended` is `true` (even if `TX-3` started streaming before `TX-2` triggered suspension).
  - **Regression test outline**: Extend `050_parallel_apply.pl`'s 16 MB suspension scenario: while `TX-2` is paused at `apply-update-before-open-indices` after crossing 16 MB, run a > `logical_decoding_work_mem` streaming `TX-3` updating/deleting the same row `id = 0`, commit `TX-3`, wake `TX-2`, and verify final row state matches the publisher.
- **Risk**: Silent data loss/divergence or spurious unique/FK/deadlock errors when a serialized streaming transaction follows a suspended parallelized transaction.
- **Suggested Fix**: Call `maintain_commit_order_dependency(NULL)` *before* `apply_spooled_messages()` in both `apply_handle_stream_commit()` (`TRANS_LEADER_APPLY`) and `apply_handle_stream_prepare()` (`TRANS_LEADER_APPLY`).

### Issue 2: Bytewise raw-wire comparison in `replica_identity_table` breaks logical equality for built-in types, nondeterministic collations, cross-type FKs, and exclusion/temporal constraints
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 778–839 (`hash_replica_identity`, `hash_replica_identity_compare`), 1445–1550 (`check_and_record_fkey_dependency`)
- **File (related)**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: 833–930 (`get_unique_indexes`), 1163–1335 (`get_local_fkeys`)
- **Description**:
  `hash_replica_identity()` and `hash_replica_identity_compare()` hash and `memcmp()` raw `LogicalRepTupleData` wire-format byte strings instead of PostgreSQL typed `Datum` equality (`typecache` / index opfamily `COMPARE_EQ` / FK `conpfeqop`). Furthermore, `get_unique_indexes()` skips `!indisunique` indexes (ignoring all `EXCLUDE` constraints) and tracks full range values for `WITHOUT OVERLAPS` (`indisexclusion`) indexes, while `get_local_fkeys()` tracks full range values for `PERIOD` (`conperiod`) FKs.
  - **Schema/Config**: Any of:
    (a) Single table `CREATE TABLE t (id numeric PRIMARY KEY, v int);` (or `float8`, `interval`, or `text COLLATE nondet_icu`).
    (b) Cross-type FK `pk (id int8 PRIMARY KEY)` + `fk (id int PRIMARY KEY, pk_id int4 REFERENCES pk(id))` with `binary = true` and replica FK triggers enabled (or `varchar` referencing `char(n)` in text/binary mode).
    (c) Exclusion/temporal constraint: `CREATE TABLE t (id int PRIMARY KEY, r int4range, EXCLUDE USING gist (r WITH &&));` or `PRIMARY KEY (id, r WITHOUT OVERLAPS)`.
  - **Schedule**:
    - Case (a): `TX-1` (`W1`, paused before commit): `INSERT INTO t VALUES (1.0, 1);` (wire `"1.0"` — or `'-0'::float8` `" -0"`, `'1 day'::interval`, `'abc'`). `TX-2` (`W2`): `DELETE FROM t WHERE id = 1.00;` (wire `"1.00"` — or `'0'::float8`, `'24 hours'::interval`, `'ABC'`).
    - Case (b): `TX-1` (`W1`): `INSERT INTO pk VALUES (1);` (`len=8`). `TX-2` (`W2`): `INSERT INTO fk VALUES (1, 1);` (`len=4`).
    - Case (c): `TX-1` (`W1`): `DELETE FROM t WHERE id = 1;` (`r = '[1,10)'`). `TX-2` (`W2`): `INSERT INTO t VALUES (2, '[5,15)');`.
  - **Consequence**: `hash_replica_identity_compare()` reports mismatch (or `EXCLUDE` isn't tracked at all). In Case (a), `TX-2` runs `DELETE` before `TX-1` commits `INSERT`, `FindReplTupleInLocalRel()` finds nothing, logs `delete_missing` and drops the delete, and `TX-1` leaves row `(1.0, 1)` on subscriber — **silent data divergence** (`TX-1: DELETE` + `TX-2: INSERT` gives unique-violation error). In Cases (b) and (c), `TX-2` fails with FK or exclusion constraint violation. Serial apply handles all three cleanly using PostgreSQL equality/exclusion operators.
  - **Attempted refutation**: Checked `proto.c:838-865` (`logicalrep_write_tuple`) and `timestamp.c:2564,2647`: neither text output nor binary send normalizes `numeric` scale, `-0.0` float sign bit, `interval` days vs hours, nondeterministic collations, or cross-type FK widths.
  - **Regression test outline**: Add tests in `050_parallel_apply.pl` for (1) `numeric` (`1.0` vs `1.00`) / `float8` (`-0` vs `0`) / `interval` (`'1 day'` vs `'24 hours'`) `INSERT`+`DELETE` dependency, (2) `int4`->`int8` FK with `binary = true`, and (3) `EXCLUDE USING gist` `DELETE`+`INSERT` overlap.
- **Risk**: Silent data divergence on `DELETE`/`UPDATE` and spurious constraint errors on unique, FK, and exclusion constraints.
- **Suggested Fix**: Key and compare dependency entries by normalized/type-aware `Datum` hash and equality (or fall back to table-level dependency for non-byte-canonical types/collations, cross-type FKs when types/formats differ, and `indisexclusion`/`conperiod` constraints by excluding non-equality columns or serializing at table level).

### Issue 3: `get_local_fkeys()` checks replica-trigger enablement on the wrong table's triggers
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: 1051–1070 (`fkey_trigger_enabled_in_replica`), 1210–1240 (`get_local_fkeys`)
- **Description**:
  In `get_local_fkeys(entry)`, when `entry` is the referenced (PK) table (`trig_type == RI_TRIGGER_PK`, populating `entry->local_refkeys` to serialize `INSERT pk` -> `INSERT fk`), line 1235 checks `fkey_trigger_enabled_in_replica(entry->localrel, con->oid, RI_TRIGGER_PK)`. However, `RI_TRIGGER_PK` triggers on the parent only run on parent `DELETE`/`UPDATE`; `INSERT` into the referencing table fires **`RI_TRIGGER_FK` (`RI_FKey_check_ins`) on the child table** (`fkentry->localrel`). Symmetrically, when `entry` is the referencing (FK) table (`trig_type == RI_TRIGGER_FK`, populating `entry->local_fkeys` to serialize `DELETE fk` -> `DELETE pk`), line 1235 checks `fkey_trigger_enabled_in_replica(entry->localrel, con->oid, RI_TRIGGER_FK)`, whereas `DELETE` from the parent fires **`RI_TRIGGER_PK` (`RI_FKey_noaction_del`) on the parent table**.
  - **Schema/Config**: `CREATE TABLE pk (id int PRIMARY KEY); CREATE TABLE fk (id int PRIMARY KEY, pk_id int REFERENCES pk(id));` on both nodes. On subscriber, user enables replica trigger checking only on `fk` (`ALTER TABLE fk ENABLE REPLICA TRIGGER ALL;`) or only on `pk` (`ALTER TABLE pk ENABLE REPLICA TRIGGER ALL;`). Both tables are already cached in `LogicalRepRelMap`.
  - **Schedule**:
    - With only `fk` triggers enabled (`REPLICA`): `TX-1` (`W1`, paused before commit): `INSERT INTO pk VALUES (1);`; `TX-2` (`W2`): `INSERT INTO fk VALUES (1, 1);`.
    - With only `pk` triggers enabled (`REPLICA`): `TX-1` (`W1`, paused before commit): `DELETE FROM fk WHERE id = 1;`; `TX-2` (`W2`): `DELETE FROM pk WHERE id = 1;`.
  - **Consequence**: `get_local_fkeys()` skips recording the FK relationship (`local_refkeys = NIL` / `local_fkeys = NIL`), `TX-2` does not wait for `TX-1`, the replica-enabled trigger fires on `TX-2`, and `TX-2` fails with a foreign key constraint violation (whereas serial apply succeeds).
  - **Attempted refutation**: Verified in `trigger.c:1767` (`EnableDisableTrigger`) that `ALTER TABLE fk ENABLE REPLICA TRIGGER ALL` only modifies `pg_trigger` rows with `tgrelid = fk` (or its partitions), not `pk`'s `RI_TRIGGER_PK` triggers.
  - **Regression test outline**: In `050_parallel_apply.pl`, test `INSERT pk` + `INSERT fk` with only `fk`'s `RI_FKey_check_ins` enabled in replica mode, and `DELETE fk` + `DELETE pk` with only `pk`'s `RI_FKey_noaction_del` enabled in replica mode.
- **Risk**: False foreign-key violations whenever replica triggers are selectively enabled on the enforcing table rather than symmetrically on both sides.
- **Suggested Fix**: When evaluating `RI_TRIGGER_PK` (`local_refkeys` on the parent), check `fkey_trigger_enabled_in_replica(..., RI_TRIGGER_FK)` on `fkentry->localrel` (the referencing table, or its parent); when evaluating `RI_TRIGGER_FK` (`local_fkeys` on the child), check `fkey_trigger_enabled_in_replica(..., RI_TRIGGER_PK)` on `fkentry->localrel` (the referenced table).

### Issue 4: `TRUNCATE` on a referencing (child) table fails to serialize subsequent `DELETE`/`UPDATE` on the referenced (parent) table
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 1445–1550 (`check_and_record_fkey_dependency`), 1717–1780 (`find_frel_dependency`)
- **Description**:
  When `LOGICAL_REP_MSG_TRUNCATE` arrives for a referencing table `fk`, `handle_dependency_on_change()` calls `check_and_record_rel_dependency(fk, TX-1, ...)` (setting `fk->last_depended_xid = TX-1`, adding nothing to `replica_identity_table`) and `find_frel_dependency(fk, TX-1, LOGICAL_REP_MSG_TRUNCATE, ...)`. Inside `find_frel_dependency()`, `fk->local_refkeys` is `NIL`, and line 1773 returns early (`if (!schema_change) return;`), so neither `pk->last_depended_xid` nor any `LOGICALREP_KEY_FOREIGN_KEY` entry is recorded. Subsequently, when `TX-2` runs `DELETE FROM pk` or `UPDATE pk` (modifying PK), `check_and_record_fkey_dependency(pk, &oldtup, true, ...)` only probes `replica_identity_table` and never inspects `fk->last_depended_xid`.
  - **Schema/Config**: `pk (id int PRIMARY KEY)` with row `(1)`, `fk (id int PRIMARY KEY, pk_id int REFERENCES pk(id))` with row `(10, 1)`, replica FK triggers enabled, both tables in `LogicalRepRelMap`.
  - **Schedule**:
    1. `TX-1` (`W1`): `BEGIN; INSERT INTO aux VALUES (1); TRUNCATE fk; COMMIT;` (paused/delayed in `W1` before executing `TRUNCATE fk`).
    2. `TX-2` (`W2`): `DELETE FROM pk WHERE id = 1;`
  - **Consequence**: `TX-2` detects no dependency on `TX-1`, executes `DELETE FROM pk` before `W1` locks/truncates `fk`, triggers `RI_FKey_noaction_del`, observes row `(10, 1)` still visible in `fk`, and aborts with a foreign key violation error (while serial apply commits `TRUNCATE fk` first and succeeds).
  - **Attempted refutation**: In PostgreSQL, `TRUNCATE fk` on a child table succeeds without `CASCADE` or touching `pk`. `RI_FKey_noaction_del` only takes `AccessShareLock` on `fk` during the `DELETE` check, so whenever `W2` reaches `DELETE FROM pk` before `W1` reaches `TRUNCATE fk` (e.g., earlier operations in `TX-1` or scheduling latency), `W2` fails.
  - **Regression test outline**: Add a test in `050_parallel_apply.pl` where `TX-1` does `INSERT INTO aux ...; TRUNCATE fk;` (held before `TRUNCATE`) and `TX-2` does `DELETE FROM pk`, verifying `TX-2` logs and waits for `TX-1`.
- **Risk**: Spurious foreign-key constraint violation errors and worker restarts after `TRUNCATE` on referencing tables.
- **Suggested Fix**: In `check_and_record_fkey_dependency()` when checking `local_refkeys` for `old_tuple`, also check `has_active_rel_dependency()` on `logicalrep_get_relentry(refinfo->fk_remoteid)` (or have `find_frel_dependency()` record table-level dependencies on `local_fkeys`'s `ref_remoteid` entries for `TRUNCATE`).

### Issue 5: Unchanged external TOAST columns outside replica identity crash `build_replica_identity_key_by_attnums()` on `Assert` and corrupt FK checks on `UPDATE`
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 1243–1295 (`build_replica_identity_key_by_attnums`), 1938–1985 (`handle_dependency_on_change` `LOGICAL_REP_MSG_UPDATE`)
- **Description**:
  When an `UPDATE` does not modify any replica-identity columns and no replica-identity column has external TOAST pointers, `ExtractReplicaIdentity()` (`src/backend/access/heap/heapam.c:4115`) returns `NULL`, so `has_oldtup == false`. Any unchanged external TOAST column outside the replica identity (e.g., a large `text` column used in a subscriber FK or referenced `UNIQUE` key) is encoded by `logicalrep_write_tuple()` (`proto.c:838`) as `LOGICALREP_COLUMN_UNCHANGED` (`'u'`) with `len == 0` and `data == NULL`.
  In `handle_dependency_on_change()` (`LOGICAL_REP_MSG_UPDATE`), `check_and_record_fkey_dependency(relid, &newtup, false, ...)` is called. Because `fk_tuple_has_null()` only checks `== LOGICALREP_COLUMN_NULL`, `build_replica_identity_key_by_attnums()` is invoked and immediately fails at line 1279:
  `Assert(original_data->colstatus[attidx] != LOGICALREP_COLUMN_UNCHANGED || original_data->colvalues[attidx].len > 0);`
  In non-assert builds, it records `colstatus = 'u'` with `len = 0` (and calls `appendBinaryStringInfo(..., NULL, 0)`), which never matches `'t'`/`'b'` keys in `replica_identity_table`.
  Additionally, if `has_oldtup == true` (e.g., `UPDATE` also changed the PK while the TOASTed FK column was unchanged), lines 1953–1961 overwrite `newtup.colstatus[i]` with `oldtup.colstatus[i]`, which is `LOGICALREP_COLUMN_NULL` (`'n'`) for non-RI columns — turning a live non-null FK value into `NULL` and skipping the FK check in `fk_tuple_has_null()`. (A row-filter `UPDATE -> INSERT` transformation on `parent` with an unchanged TOASTed non-RI `uk` column hits the same `Assert` on `LOGICAL_REP_MSG_INSERT`.)
  - **Schema/Config**: `CREATE TABLE parent (id int PRIMARY KEY, uk text UNIQUE, other int); ALTER TABLE parent ALTER COLUMN uk SET STORAGE EXTERNAL;` and `CREATE TABLE child (cid int PRIMARY KEY, fk text REFERENCES parent(uk), other int);` with replica FK triggers enabled.
  - **Schedule**: `INSERT INTO parent VALUES (1, repeat('x', 5000), 1);` then `UPDATE parent SET other = 2 WHERE id = 1;` (or `UPDATE child SET other = 2 WHERE cid = 1;`).
  - **Consequence**: Immediate `SIGABRT` assertion crash in leader apply worker (or corrupted zero-length `'u'` key / skipped FK check in release builds). Serial apply handles the update without error.
  - **Attempted refutation**: Confirmed in `heapam.c:4115` that `ExtractReplicaIdentity` receives `key_required = false` when `id_attrs` (`id`) is integer and unmodified; confirmed `proto.c:838` emits `LOGICALREP_COLUMN_UNCHANGED` (`len = 0`).
  - **Regression test outline**: Add a test in `050_parallel_apply.pl` with an external TOASTed `UNIQUE` / `REFERENCES` column outside the PK/RI and run `UPDATE` on an unrelated column (both with and without changing the PK).
- **Risk**: Immediate worker crash on assert-enabled builds and silent loss of FK dependency tracking in non-assert builds for tables with TOASTed FK columns.
- **Suggested Fix**: In `handle_dependency_on_change()`, only copy `oldtup` entries onto `newtup` when `oldtup.colstatus[i] != LOGICALREP_COLUMN_NULL` (or only for `attkeys` columns); in `check_and_record_fkey_dependency()` (and `build_replica_identity_key_by_attnums()`), detect `LOGICALREP_COLUMN_UNCHANGED` with `len == 0` and fall back to table-level FK dependency checking (`find_all_dependencies_on_rel` / `last_depended_xid`) instead of assuming the full value is present.

### Issue 6: `get_unique_indexes()` skips `DEFERRABLE INITIALLY IMMEDIATE` unique constraints (`!indimmediate`)
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: 851–862 (`get_unique_indexes`)
- **Description**:
  `get_unique_indexes()` skips any unique index with `!idxrel->rd_index->indimmediate`, assuming its uniqueness is only checked at commit time. However, in PostgreSQL, a `DEFERRABLE INITIALLY IMMEDIATE` unique constraint (`CONSTRAINT u UNIQUE (val) DEFERRABLE INITIALLY IMMEDIATE`) has `indimmediate = false` in `pg_index`, while its `unique_key_recheck` trigger has `tginitdeferred = false`. As implemented in `execIndexing.c:446`, `trigger.c:6550`, `worker.c:2466` (`AfterTriggerEndQuery` in `finish_edata`), and `constraint.c:39` (`unique_key_recheck`), `unique_key_recheck` fires **immediately at the end of each DML step** (`AfterTriggerEndQuery`), not at `COMMIT`.
  - **Schema/Config**: `CREATE TABLE t (id int PRIMARY KEY, val int, CONSTRAINT u_val UNIQUE (val) DEFERRABLE INITIALLY IMMEDIATE);` on subscriber with initial row `(1, 100)`.
  - **Schedule**:
    1. `TX-1` (`W1`): `BEGIN; INSERT INTO aux VALUES (1); DELETE FROM t WHERE id = 1; COMMIT;` (paused/delayed in `W1` before executing `DELETE`).
    2. `TX-2` (`W2`): `INSERT INTO t VALUES (2, 100);`
  - **Consequence**: `u_val` is excluded from `local_unique_indexes`, so `TX-2` does not wait for `TX-1`. `W2` executes `INSERT (2, 100)` before `W1` deletes `(1, 100)`, `AfterTriggerEndQuery` invokes `unique_key_recheck` immediately, sees live `(1, 100)`, and fails with `duplicate key value violates unique constraint "u_val"`. Serial apply deletes `(1, 100)` first and succeeds. (Note `get_local_fkeys()` at `relation.c:1203` properly checks `con->condeferrable && con->condeferred`.)
  - **Attempted refutation**: Verified `AfterTriggerEndQuery(estate)` runs in `finish_edata()` (`worker.c:2466`) at the end of `apply_handle_insert` and `apply_handle_update`, firing all triggers without `AFTER_TRIGGER_INITDEFERRED`.
  - **Regression test outline**: In `050_parallel_apply.pl`, add a `DEFERRABLE INITIALLY IMMEDIATE` unique constraint, pause `TX-1` (`INSERT aux; DELETE t`) before `DELETE`, run `TX-2` (`INSERT t` with the deleted unique value), and verify `TX-2` waits and succeeds.
- **Risk**: False unique-constraint violation errors and apply restarts whenever `DEFERRABLE INITIALLY IMMEDIATE` unique constraints exist on the subscriber.
- **Suggested Fix**: In `get_unique_indexes()`, only skip `!idxrel->rd_index->indimmediate` indexes when their backing `pg_constraint` entry is actually `condeferrable && condeferred` (`INITIALLY DEFERRED`).

### Issue 7: `REPEATABLE READ`/`SERIALIZABLE` parallel workers freeze `FirstXactSnapshot` before waiting on dependencies
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 2175–2189 (`begin_replication_step`), 7745–7790 (`InitializeLogRepWorker`)
- **Description**:
  `InitializeLogRepWorker()` sets `session_replication_role = replica`, `search_path = ""`, and `default_transaction_read_only = off`, but does not override `default_transaction_isolation` to `'read committed'`. When `default_transaction_isolation` is `'repeatable read'` or `'serializable'` (`IsolationUsesXactSnapshot() == true`), `GetTransactionSnapshot()` (`snapmgr.c:302-330`) caches `FirstXactSnapshot` on the first `begin_replication_step()` of a transaction and returns that same snapshot for all subsequent steps in the transaction.
  - **Schema/Config**: Subscriber database/role/cluster configured with `default_transaction_isolation = 'repeatable read'` (or `'serializable'`); `pk (id int PRIMARY KEY)`, `fk (id int PRIMARY KEY, pk_id int REFERENCES pk(id))` with replica FK triggers enabled (or a `STABLE`/`VOLATILE` replica trigger reading `pk`), and an unrelated table `u (id int PRIMARY KEY)`.
  - **Schedule**:
    1. `TX-1` (`W1`, paused before commit): `INSERT INTO pk VALUES (1);`.
    2. `TX-2` (`W2`): `BEGIN; INSERT INTO u VALUES (1); INSERT INTO fk VALUES (1, 1); COMMIT;`.
  - **Consequence**: `W2` applies `INSERT INTO u VALUES (1)` first because `u` has no dependency on `TX-1`, taking and freezing `FirstXactSnapshot` *before* `TX-1` commits. `W2` then receives `PA_MSG_XACT_DEPENDENCY [TX-1]`, waits for `W1` to commit `TX-1`, and runs `INSERT INTO fk VALUES (1, 1)`. Both `ri_FastPathCheck()` (`ri_triggers.c:2847`) and `ri_PerformCheck()` (`ri_triggers.c:2689`) use `GetTransactionSnapshot()`, which returns the stale `FirstXactSnapshot` that cannot see `TX-1`'s committed row in `pk`, failing with an FK violation error (or serialization error for partitioned `pk`, or stale query results in `STABLE`/`VOLATILE` triggers). In serial apply, `TX-1` commits before `TX-2` takes its snapshot.
  - **Attempted refutation**: Checked `InitializeLogRepWorker()` (`worker.c:7745`) and `snapmgr.c:272-335`: `default_transaction_isolation` is not overridden, and `GetTransactionSnapshot()` never refreshes when `FirstSnapshotSet && IsolationUsesXactSnapshot()`.
  - **Regression test outline**: Set `default_transaction_isolation = 'repeatable read'` on the subscriber, hold `TX-1` (`INSERT pk`) before commit, send `TX-2` (`INSERT unrelated; INSERT fk`), and verify `TX-2` succeeds without FK or serialization errors.
- **Risk**: Spurious FK violations, serialization failures, and stale trigger snapshots in parallel apply when subscriber default isolation is `REPEATABLE READ` or `SERIALIZABLE`.
- **Suggested Fix**: Force `SetConfigOption("default_transaction_isolation", "read committed", PGC_BACKEND, PGC_S_OVERRIDE)` in `InitializeLogRepWorker()`, or defer taking `FirstXactSnapshot` / disallow parallel apply when `IsolationUsesXactSnapshot()` is active.

### Issue 8: `check_relation_parallel_apply_safety()` skips partitioned root `DEFAULT`s in `slot_fill_defaults()` and fails to serialize following safe-table transactions after an unsafe transaction
- **Severity**: High
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 1806–1854 (`check_relation_parallel_apply_safety`), 4537–4553 (`apply_handle_insert`)
- **File (related)**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: 672–751 (`logicalrep_rel_check_parallel_safety`)
- **Description**:
  Two safety-tracking gaps exist:
  1. **Root `DEFAULT` evaluation on partitioned tables**: At `apply_handle_insert()` line 4537, `check_relation_parallel_apply_safety(rel, LRPA_INSERT)` returns early at line 1822 when `rel->localrel->rd_rel->relkind == RELKIND_PARTITIONED_TABLE`. Immediately afterward at line 4549, `slot_fill_defaults(rel, estate, remoteslot)` evaluates local `DEFAULT` expressions on the *root* partitioned table `rel` before `apply_handle_tuple_routing()` checks the leaf partition. If the root table has a local-only column with a volatile `DEFAULT` (e.g., `DEFAULT nextval('seq')` or `DEFAULT my_volatile_fn()`) — especially if an attached leaf partition lacks that default via `ATTACH PARTITION` — the volatile `DEFAULT` executes in parallel without waiting for `preceding_xid`. Also, `logicalrep_rel_check_parallel_safety()` line 744 only marks `LRPA_INSERT` when checking stored generated columns (`attgenerated == ATTRIBUTE_GENERATED_STORED`), even though `ExecComputeStoredGenerated()` also runs on `UPDATE` (`execReplication.c:1020`) if a function's volatility was altered via `ALTER FUNCTION`.
  2. **One-sided serialization for unsafe relations**: `check_relation_parallel_apply_safety()` only makes a transaction touching an *unsafe* relation wait for `preceding_xid`; it never records that the transaction itself is unsafe so that a subsequent transaction touching a *safe* relation waits for it.
  - **Schema/Config**:
    - For (1): Publisher `pt (id int PRIMARY KEY)`; subscriber `pt (id int PRIMARY KEY, seq int DEFAULT nextval('s')) PARTITION BY RANGE (id)` with attached `pt_1 (id int PRIMARY KEY, seq int)` (no leaf default).
    - For (2): Subscriber `t_unsafe` has an `AFTER INSERT` replica trigger (`VOLATILE`) that inserts/updates row `(99)` in `t_safe` (which has no triggers/defaults of its own).
  - **Schedule & Consequence**:
    - In (1): Parallel transactions execute `nextval('s')` / volatile default on `pt` out of order without waiting on `preceding_xid`.
    - In (2): `TX-1` (`W1`, paused before trigger inserts `(99)` into `t_safe`) inserts into `t_unsafe`; `TX-2` (`W2`) deletes `(99)` from `t_safe` (`t_safe` is safe and has no recorded dependency on `t_safe` from `TX-1`). `W2` runs `DELETE` before `W1`'s trigger runs, logs `delete_missing` and drops the delete, then `W1`'s trigger inserts `(99)` and commits -> **silent data divergence** (or deadlock if `W2` inserts `(99)` in `t_safe`, waits for `W1` at commit, and `W1`'s trigger blocks on `(99)`). Serial apply runs `TX-1` and its trigger to completion before `TX-2` starts.
  - **Attempted refutation**: Verified `apply_handle_insert()` evaluates `slot_fill_defaults(rel, ...)` before `apply_handle_tuple_routing()`, and `check_relation_parallel_apply_safety(t_safe)` checks only `t_safe->parallel_global_unsafe`.
  - **Regression test outline**: In `050_parallel_apply.pl`, add (a) a partitioned root with a volatile `DEFAULT` and an attached leaf without the default, verifying `wait for depended xid` occurs before evaluating `DEFAULT`; and (b) `TX-1` with a replica trigger modifying `t_safe` followed by `TX-2` modifying the same key in `t_safe`, verifying `TX-2` does not run concurrently with `TX-1`.
- **Risk**: Out-of-order volatile `DEFAULT` execution on partitioned tables, deadlocks, and silent data divergence when unsafe triggers touch other tables.
- **Suggested Fix**: Check root `DEFAULT` (and `GENERATED STORED` on `LRPA_INSERT`/`LRPA_UPDATE`) safety in `logicalrep_rel_check_parallel_safety()` even for partitioned tables before `slot_fill_defaults()`, and track whether an in-flight parallel transaction has executed an unsafe operation (e.g., in `ParallelizedTxnEntry` or leader state) so subsequent transactions wait for it before applying changes to any table.

### Issue 9: Concurrent `ALTER SUBSCRIPTION ... SKIP (lsn = NONE)` race in `apply_handle_begin()` leaks `skip_xact_finish_lsn`
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 2774–2826 (`apply_handle_begin`), 2860–2935 (`apply_handle_commit`)
- **File (related)**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c`
- **Line(s)**: 478–535 (`pa_can_start`)
- **Description**:
  In `apply_handle_begin()`, `maybe_start_skipping_changes(begin_data.final_lsn)` runs *before* `pa_allocate_worker()`, which invokes `pa_can_start()`. `pa_can_start()` calls `AcceptInvalidationMessages(); maybe_reread_subscription();` (lines 502–503). If `MySubscription->skiplsn` matches `begin_data.final_lsn` when `apply_handle_begin()` starts, `maybe_start_skipping_changes()` sets `skip_xact_finish_lsn = begin_data.final_lsn`. If another session concurrently ran `ALTER SUBSCRIPTION ... SKIP (lsn = NONE)` while the leader was draining messages in `LogicalRepApplyLoop`'s inner loop, `pa_can_start()` reloads `MySubscription->skiplsn = InvalidXLogRecPtr`, passes the `skiplsn` check, and assigns a parallel worker (`TRANS_LEADER_SEND_TO_PARALLEL`).
  - **Schema/Config**: Subscription with `skiplsn = LSN_T1` and `streaming = parallel`.
  - **Schedule**: Leader processes `TX-0` and reads `TX-1` (`BEGIN` at `LSN_T1`) from the socket buffer in the same `LogicalRepApplyLoop` receive burst while another session executes `ALTER SUBSCRIPTION sub SKIP (lsn = NONE)`.
  - **Consequence**: Leader sends `BEGIN` to the parallel worker, skips all DML in `TX-1` (`is_skipping_changes() == true`), and at `COMMIT` takes `case TRANS_LEADER_SEND_TO_PARALLEL`, forwarding `COMMIT` without calling `stop_skipping_changes()` on the leader (unlike `apply_handle_commit_internal()` or `apply_handle_prepare()`). Because `is_skipping_changes()` is `false` in the parallel worker, `skip_xact_finish_lsn` remains non-zero on the leader, causing `Assert(!is_skipping_changes())` crash on the next `BEGIN` (or silently skipping all future transactions in non-assert builds).
  - **Attempted refutation**: Verified `apply_handle_commit()` in `TRANS_LEADER_SEND_TO_PARALLEL` does not call `apply_handle_commit_internal()` or `stop_skipping_changes()` on the leader, and `maybe_reread_subscription()` does not exit on `skiplsn` changes.
  - **Regression test outline**: Add a test or injection-point check between `maybe_start_skipping_changes` and `pa_can_start` clearing `subskiplsn`, verifying `pa_can_start()` returns `false` when `is_skipping_changes()` is true.
- **Risk**: Leader apply worker assertion crash or silent skipping of all subsequent replicated transactions.
- **Suggested Fix**: Return `false` immediately in `pa_can_start()` if `is_skipping_changes()` is true, and/or call `AcceptInvalidationMessages(); maybe_reread_subscription();` before `maybe_start_skipping_changes()` in `apply_handle_begin()` and `apply_handle_begin_prepare()`.

### Issue 10: `LOGICAL_REP_MSG_RELATION` reads stale `LogicalRepPartMap` entries in `handle_dependency_on_change()`, and `get_local_fkeys()` accesses unlocked `otherrelid` partitions
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 2028–2043 (`handle_dependency_on_change`), 4419–4430 (`apply_handle_relation`)
- **File (related)**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/relation.c`
- **Line(s)**: 1020–1044 (`logicalrep_map_attnums_by_name`), 1255–1295 (`get_local_fkeys`)
- **Description**:
  Two cache/locking hazards exist around schema metadata:
  1. In `handle_dependency_on_change()` (`LOGICAL_REP_MSG_RELATION`), `logicalrep_relmap_update(rel)` is called at line 2038 followed immediately by `find_frel_dependency(rel->remoteid, ...)` before `logicalrep_partmap_reset_relmap(rel)` is called at line 4427 (`apply_handle_relation()`). When `rel` is a partitioned table whose leaf partitions were cached in `LogicalRepPartMap`, `find_frel_dependency()` -> `build_local_dependent_key_info()` -> `logicalrep_partition_open()` sees `entry->localrelvalid == true` and reuses stale `LogicalRepPartMap` entries carrying the *old* `remoterel` (`attkeys`) and `attrmap`. Afterward, `apply_handle_relation()` calls `logicalrep_relmap_update(rel)` a second time, discarding the derived unique/FK caches just built.
  2. In `get_local_fkeys()` (`relation.c:1260`), when `entry` is the referenced (`PK`) table, we only hold `AccessShareLock` on `entry->localrel`, yet it executes `find_all_inheritors(otherrelid, NoLock, NULL)` and `logicalrep_map_attnums_by_name(otherrelid, fkentry->localreloid, ...)` without locking `otherrelid` or its partitions (`fk_parted_1`). Concurrent DDL that only locks `fk_parted` (e.g., `ALTER TABLE fk_parted RENAME COLUMN ...`) does not acquire any lock on `pk`, so `get_attname(otherrelid, ...)` and `get_attnum(fkentry->localreloid, ...)` can race, returning `InvalidAttrNumber` (`0`) and hitting `Assert(AttributeNumberIsValid(attnum))` at `relation.c:1040` (or negative out-of-bounds `AttrNumberGetAttrOffset(0)` indexing in `build_fk_remote_attnums()`).
  - **Schema/Config**: (1) Partitioned table on subscriber receiving a `RELATION` schema/RI update after prior tuple routing; (2) `pk` + partitioned `fk_parted` with concurrent `ALTER TABLE fk_parted RENAME COLUMN`.
  - **Consequence**: Stale FK/unique key metadata during `find_frel_dependency()` in (1); `Assert` crash or out-of-bounds `attrmap->attnums[-1]` read in (2).
  - **Attempted refutation**: Verified `logicalrep_partmap_reset_relmap()` is not called inside `logicalrep_relmap_update()` (`relation.c:280`) or `handle_dependency_on_change()`, and `ATExecRenameColumn` only locks the target table (`fk_parted`), not `confrelid` (`pk`).
  - **Regression test outline**: Add a test updating `REPLICA IDENTITY` / schema on a partitioned table after caching `LogicalRepPartMap` entries, and verify `LogicalRepPartMap` is reset before `find_frel_dependency()`.
- **Risk**: Incorrect dependency key calculation across partitioned schema updates and crash/OOB read on concurrent referencing-table column rename.
- **Suggested Fix**: Call `logicalrep_partmap_reset_relmap(rel)` immediately alongside `logicalrep_relmap_update(rel)` in `handle_dependency_on_change()` (and avoid redundant `logicalrep_relmap_update()` in `apply_handle_relation()`), and acquire `AccessShareLock` (with `try_table_open` / safe handling if missing) on `otherrelid` and `fkentry->localreloid` during `get_local_fkeys()` / `logicalrep_map_attnums_by_name()`.

### Issue 11: Streaming transactions error out in `send_internal_dependencies()` instead of switching to `PARTIAL_SERIALIZE` on `shm_mq` timeout
- **Severity**: Medium
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/worker.c`
- **Line(s)**: 2289–2305 (`handle_streamed_transaction`), 8430–8449 (`send_internal_dependencies`)
- **Description**:
  In `handle_streamed_transaction()` under `TRANS_LEADER_SEND_TO_PARALLEL`, line 2289 calls `handle_dependency_on_change(action, s, InvalidTransactionId, winfo)`, and line 2297 checks `if (!winfo->serialize_changes && pa_send_data(winfo, s->len, s->data))`, anticipating that `handle_dependency_on_change()` might transition `winfo` to `PARTIAL_SERIALIZE` if the worker's `shm_mq` is full. However, when `depends_on_xids != NIL`, `send_internal_dependencies()` calls `pa_send_data(winfo, ...)` and unconditionally executes `ereport(ERROR, ...)` on timeout (`worker.c:8443`), rather than switching the streamed transaction to `PARTIAL_SERIALIZE`.
  - **Schema/Config**: `streaming = parallel`, `logical_decoding_work_mem = 64kB`.
  - **Schedule**: A parallel streaming worker `W1` is temporarily blocked on a lock held by a local backend while its 16 MB `shm_mq` fills up; the next streamed chunk contains a change depending on an in-flight non-streamed transaction `TX-0`, triggering `send_internal_dependencies(W1, ...)`.
  - **Consequence**: Instead of cleanly falling back to `PARTIAL_SERIALIZE` (as streaming transactions normally do on send timeout), the leader apply worker errors out and aborts/restarts replication.
  - **Attempted refutation**: Confirmed `send_internal_dependencies()` is the only `pa_send_data()` call inside `handle_streamed_transaction()` that raises `ERROR` without calling `pa_switch_to_partial_serialize()`; `pa_switch_to_partial_serialize()` is only invoked afterward at line 2305.
  - **Regression test outline**: Extend `015_stream.pl` or `050_parallel_apply.pl` with `debug_logical_replication_streaming = 'immediate'` (or full queue) when a streamed chunk has a dependency on an in-flight non-streamed transaction, verifying fallback to `PARTIAL_SERIALIZE` instead of worker `ERROR`.
- **Risk**: Unnecessary apply worker failure and restart for streaming transactions experiencing lock contention/backpressure when a dependency message is emitted.
- **Suggested Fix**: Allow `send_internal_dependencies()` (or `handle_dependency_on_change()`) to detect `in_streamed_transaction` and fall back to `pa_switch_to_partial_serialize()` (waiting on `depends_on_xids` before `pa_xact_finish()` or writing a `PA_MSG_XACT_DEPENDENCY` record to the spool file).

### Issue 12: Documentation is stale for non-streaming parallel apply, runtime `SIGHUP` pool reduction misses fast-path check, and `050_parallel_apply.pl` enables FK triggers non-deterministically
- **Severity**: Low
- **File**: `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/config.sgml`, `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/logical-replication.sgml`, `/home/maheshbehera/worktrees/postgresql-v28-review/doc/src/sgml/ref/create_subscription.sgml`
- **Line(s)**: `config.sgml:5801-5809`, `logical-replication.sgml:2556,2757-2761`, `create_subscription.sgml:344-351`
- **File (related)**: `/home/maheshbehera/worktrees/postgresql-v28-review/src/backend/replication/logical/applyparallelworker.c` (`line 702`), `/home/maheshbehera/worktrees/postgresql-v28-review/src/test/subscription/t/050_parallel_apply.pl` (`lines 1118-1134, 1274-1291`)
- **Description**:
  1. Documentation across `config.sgml`, `logical-replication.sgml`, and `create_subscription.sgml` still states that `streaming = parallel` and `max_parallel_apply_workers_per_subscription` apply only to streaming of in-progress transactions, and omits operational guidance on `max_logical_replication_workers` sizing (note that default `4` is now exhausted by just two subscriptions each keeping up to 2 parallel workers, requiring test bumps in `001_rep_changes.pl`, `010_truncate.pl`, `026_stats.pl`, and `027_nosuperuser.pl`) and memory-limit suspension/resume (`parallel apply suspended`/`resumed`).
  2. In `pa_launch_parallel_worker()` (`applyparallelworker.c:702`), `if (list_length(ParallelApplyWorkerPool) == max_parallel_apply_workers_per_subscription)` misses the fast-path exit if `max_parallel_apply_workers_per_subscription` was decreased via `SIGHUP` (`pg_reload_conf()`) below `list_length(ParallelApplyWorkerPool)`, unnecessarily allocating a DSM segment in `pa_setup_dsm()` before `logicalrep_worker_launch()` rejects it.
  3. In `050_parallel_apply.pl` lines 1118–1134 and 1274–1291, `SELECT tgname FROM pg_trigger ... AND tgconstraint > 0 LIMIT 1` without `ORDER BY` enables only one arbitrarily ordered FK trigger on `regress_tab_pk`/`pk_parted_1` (`RI_FKey_noaction_del` vs `RI_FKey_noaction_upd`), so `DELETE - DELETE` may not actually exercise the delete trigger check.
- **Risk**: Outdated user documentation causing misconfigured `max_logical_replication_workers` limits; minor wasted DSM allocation on `SIGHUP` reduction; non-deterministic trigger enablement in TAP test.
- **Suggested Fix**: Update the SGML documentation for non-streaming parallel apply and worker pool sizing; change `==` to `>=` at `applyparallelworker.c:702`; enable all `tgconstraint > 0` triggers (as done at lines 1425–1435) or add deterministic filtering in `050_parallel_apply.pl`.

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

### Issue 5
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 6
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 7
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 8
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 9
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 10
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 11
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending

### Issue 12
- **Status**: Open
- **What changed**: pending
- **Why**: pending
- **How verified**: pending