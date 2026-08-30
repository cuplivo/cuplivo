# ADR-0044: Preserve Message Versions on Fork — In-Pipeline, Not Repo-Level

Port of upstream Kelivo `feat(chat): add a switch to keep message versions when
forking`: a Display & Behavior setting that makes "创建分支" carry every
regenerated version of kept groups instead of the single selected version.

## Why the existing pipeline, not upstream's repo method

Upstream added a transactional repo-level `forkConversationWithVersions`
(`ChatDatabaseRepository`) that re-implements the anchor cut in SQL: first
order per group, keep rows where `firstOrder <= anchorOrder`. We kept the cut
in the existing in-memory pipeline — `selectForkConversationMessages` +
`ChatService.forkConversation` — extended with a `preserveVersions` mode.

- One anchor implementation. The repo method would be a second cut semantic
  alongside `selectForkConversationMessages` — a known test-count bug class
  here (AGENTS §3.20 "no parallel implementations").
- Source of truth stays the live controller list (`getMessagesRange` over the
  current conversation), not raw DB rows, so the fork continues to follow
  message-version state as the running app sees it.
- No schema change, no new migration, no build_runner regeneration — the fork
  reads and writes message fields that already exist.

The preserve-path write is still transactional, via an existing repo batch:
`ChatDatabaseRepository.putMigrationBatch` (conversation row + ordered message
rows + tool-event rows + Gemini-signature rows, one `_db.transaction`). This is
the repository's established batch shape — no new write API was invented for
the fork. The plain (non-preserve) fork stays N-`putMessage`, unchanged.

## Deviations from upstream, intentional

- **Selection value semantics**: upstream writes `selections[targetGroup] =
  target.version` (a version number). Our `versionSelections` values are
  consumed as indices into the sorted-by-version list
  (`collapseWithSelections`), though some writers historically store raw
  version numbers — the two spaces coincide only while a group's versions are
  contiguous from 0. The preserve fork copies kept groups' source selections
  verbatim (preserving source-equivalent collapse behavior, since the cut is
  an exact per-group version-list copy) and forces the target group to the
  forked-off revision via `indexWhere(id == target.id)`.
- **`subgroupId` is stripped** (Cuplivo-only concept; upstream has no
  multi-AI): preserve-mode forks never re-enter card rendering.
- **Tool events + Gemini signatures are carried** (upstream carries parts/
  artifacts — the equivalent; Cuplivo's plain fork never carried them, and the
  preserve mode is the fidelity mode, so "same rendering as source" wins).
  The capture uses the temp-aware service accessors and runs BEFORE
  `createConversation` — `createConversation` discards a temporary source
  conversation, which would otherwise purge its in-memory fidelity maps.
- **Title**: the preserve fork keeps the default title from
  `getTitleForLocale`, not `source.title` — fork naming is unchanged by the
  toggle state (upstream's preserve branch passes `source.title`).
- **Internal fork callers untouched**: compress keep-recent and multi-AI
  synthesize keep `preserveVersions: false`.

## Consequences

- New settings key `chat_fork_keep_message_versions_v1` (default OFF), riding
  `settings.json` backup/LAN sync like every flat scalar.
- Fork conversations can be large: a long rolled history duplicates into the
  branch. Stored in SQLite rows like any ordinary message — no new table.
- Regression tests land at the service + selection-function level
  (`ChatService fork conversations` group,
  `selectForkConversationMessages`), not a repo-level test file.
