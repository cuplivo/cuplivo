# ADR-0019: Schema Self-Heal: Repair Silent Migration Gaps on Every Open

Restore the runtime schema self-heal in `AppDatabase` that was added and
removed inside the v2.4.0 release cycle. The heal (`_healSchemaIfNeeded`)
idempotently checks, on every database open, that every column/table added by
the v5–v13 migrations actually exists, and adds whatever is missing. It runs in
`beforeOpen` (rescues DBs whose `user_version` already advanced past a failed
step) and again at the end of `onUpgrade` (rescues gaps just created by the
upgrade in this session).

## Context

Individual `addColumn` / `createTable` steps in the per-version migration chain
are wrapped in silent `try/catch (_) {}` for idempotent replay ("the column may
already exist"). The catches swallow *any* failure, not just "duplicate
column": a genuinely failed ALTER (disk full, interrupted upgrade, WAL error)
leaves `user_version` advanced while the schema stays incomplete. Because later
upgrades skip the failed step's `from < N` block, the gap becomes permanent.
The failure mode is a crash on insert ("table X has no column named Y").

Real-user evidence: the v12 block (`discoverable`/`handoff_*`, shipped in
v2.3.0) and the v8 block (`is_preset`) both produced reports of DBs with
advanced `user_version` but missing columns. Such DBs upgraded to v2.4.0
(schema 14) are unrecoverable by migration — `from == 14` means `onUpgrade`
never runs the failed blocks again. Only a `beforeOpen` repair can rescue them.
The alternative stance shipped with v2.4.0 ("a corrupted dev DB is repaired by
reinstalling") is data loss for chat history, not a fix.

The heal does NOT cover `director_message_rows`: schema v14 deliberately
dropped that table (the Director session is ephemeral, rebuilt from the public
transcript). Restoring the historical heal verbatim would have resurrected it.

## Considered Options

1. **Restore the heal (chosen).** Full v5–v13 set minus `director_message_rows`
   creation: 13 assistant columns, 3 message columns, 2 conversation columns,
   4 tables (`group_chat_rows`, `group_chat_member_rows`, `deleted_record_rows`,
   `deletion_marker_rows`), 2 group-chat columns. Dual placement (`beforeOpen` +
   `onUpgrade` tail), unconditional every open, `debugPrint` when it actually
   alters anything. The v11 "one try wrapping two createTable" weakness is
   covered by per-table existence checks.
2. **Reinstall as the fix (the v2.4.0 stance).** Rejected: real-user incidents
   exist (v8, v12); reinstalling clears chat history. "Corrupted dev DB" does
   not describe the reported population.
3. **Minimal set (v12 handoff columns only).** Rejected: the same silent-catch
   gap class exists in every migration block from v3 to v13 (only v7/v13 have a
   fail-stop `UPDATE` sentinel, and even v13's sentinel does not cover
   `speaker_assistant_id`); real incidents beyond v12 prove the class is not
   hypothetical.
4. **Harden the catches instead (fail only on non-duplicate errors).** Deferred
   to a separate task: with the heal in place, a swallowed failure degrades from
   "permanent gap" to "gap repaired next launch", so the root-cause hardening
   becomes hygiene with real behavioral-change risk in 12 migration sites.

## Consequences

- Every open pays ~25 idempotent `PRAGMA table_info` / `sqlite_master` queries
  (milliseconds). No conditional gating to keep the heal stateless.
- MIRROR CONSTRAINT: any new migration column/table must update the heal set
  and the regression tests in the same change (AGENTS.md §3.20), or the heal
  silently stops covering future gaps.
- `director_message_rows` is never re-created; its absence remains the v14
  contract.
- Regression tests reproduce the two incident shapes: `user_version=14` with
  `is_preset` missing (v8 shape, onUpgrade cannot run) and `user_version=13`
  with handoff columns missing (v12 shape), plus a table-creation shape.
- No telemetry/metrics are added; `debugPrint` is the observability channel for
  now (a future incident-rate study could add counters).
