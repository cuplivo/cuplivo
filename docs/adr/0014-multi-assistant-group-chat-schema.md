# ADR-0014: Multi-Assistant Group Chat: Two New Tables + Two Columns (schema v13, director table dropped in v14)

Group chat persistence uses 2 new tables (`GroupChatRows`, `GroupChatMemberRows`) plus 2 new columns (`conversation_kind`, `speaker_assistant_id`) on existing tables, instead of the MultiAI-style "just add a column" approach. MultiAI's `subgroupId` was sufficient because it added an attribute to an existing entity (the message); group chat introduces entity shapes that existing tables cannot carry.

Schema v13 originally added a third table, `DirectorMessageRows` (the Director's persisted private session). In v14 it was dropped: the Director session is ephemeral — each director call is rebuilt from the public transcript (`buildApiMessagesFromPublic`), so the table had no live writer. See the "Director session" entry in CONTEXT.md.

The Director Logs page is a read-only projection of that same design. It rebuilds
the public decision trace from the current transcript and may overlay bounded
runtime metadata held only in `GroupChatProvider` for the current app process.
Runtime metadata is not a Director session: it is not written to Drift,
SharedPreferences, backups, or the recycle bin, and is discarded when the group
is deleted or the application process ends.

## Considered Options

1. **Columns-only (extend ConversationRows/MessageRows).** Rejected: membership is a real M:N relationship (repo pattern = join table, cf. `ConversationMcpServerRows`); 10+ group-only config/runtime columns would pollute the conversation table; a JSON member list is off-pattern for entity relationships in this repo.

2. **Director session in MessageRows with a marker column.** Rejected: it is a second, unbounded append-only stream; every public-stream consumer (context building, memory, summary, backup, trash restore, version collapse) would need to filter it — a large regression surface. `getMessages` stays clean by construction instead.

3. **Director session as a JSON blob on the group row.** Rejected: each turn appends → full-log JSON rewrite per turn (O(n²) write amplification over the chat's lifetime), and no typed queries.

4. **Typed tables per entity shape (chosen).** `GroupChatRows` (metadata + per-round runtime state, FK cascade from `ConversationRows`), `GroupChatMemberRows` (M:N join, same shape as `ConversationMcpServerRows`). Two attribute columns on existing entities (`conversation_kind`, `speaker_assistant_id`) follow the MultiAI column precedent where the shape is genuinely "an attribute of an existing entity".

5. **Persist the Director session as an append-only typed table (chosen at v13, dropped at v14).** `DirectorMessageRows` with a `(groupChatId, messageOrder)` index was the original design. It was removed in v14 because the live flow stopped writing to it: director history is derived from the public transcript on every call (single source of truth, no dual state). The v14 migration drops the table (`DROP TABLE IF EXISTS director_message_rows`); backup/trash sections for it were removed in the same change. This was safe because the branch has not shipped.

## Consequences

- Schema v12 → v13: migration creates 2 tables + 2 columns (the v13 `director_message_rows` table was dropped by v14). The migration blocks follow the existing per-version `onUpgrade` pattern.
- Schema v13 → v14: `DROP TABLE IF EXISTS director_message_rows`.
- Group chat is a first-class recoverable entity (`DeletionEntityType.groupChat`) with its own trash bundle (group + members), independent of the conversation trash record.
- Backup chats.json v2 gains 2 sections (`groupChats` / `groupMembers`); the `directorMessages` section never ships — the director session is rebuilt from the restored public transcript.
- Sync rule: any future group-related table must be wired into `clearAllData` (child-before-parent FK order), backup export, and backup restore in the same change.
