# ADR-0065: Knowledge Base Storage and Backup Contract (知识库数据与备份契约)

The issue #389 proposal claimed same-database storage makes backup/sync "zero extra work" and only persisted document metadata plus chunks. Neither holds: Cuplivo backups never copy the SQLite file — each table is wired explicitly into export, restore, `clearAllData`, and the LAN-sync delta protocol (see ADR-0051 and the group-chat schema rule). This ADR fixes what is the source of truth, how the feature enters the backup format, and where assistant bindings live.

Status: accepted

## Decision

1. **Document text is the source of truth**: a Knowledge Document row stores the extracted plain text; chunk rows and the FTS index are derived data, rebuildable from text. Changing chunk size/overlap re-chunks from stored text without re-importing the file. Chunk IDs stay stable for citations and for the future vector mapping.
2. **Three typed Drift tables** (`knowledge_base`, `knowledge_document`, `knowledge_chunk`) in the existing database, plus ONE hand-managed FTS5 virtual table. Virtual tables cannot go through the Drift migrator, so they must be created in both the version migration and `_healSchemaIfNeeded()`, cleared in `clearAllData` (child-before-parent: chunk → document → base), and covered by the schema-heal discoverable test.
3. **Assistant binding is a KV map** (`knowledge_base_ids_by_assistant_v1`) in `preference_rows`, mirroring WorldBook's map with the `__global__` fallback — deliberately NOT a typed join table, which would add a fourth table's worth of backup/LAN/clear/refresher wiring for a small assistantId→kbId map.
4. **Backup gets a 7th `BackupContentScope` bit (知识库, default on)**: KB metadata and document text export as a new streaming JSONL section; restore rebuilds chunks and the FTS index from text. Legacy compatibility is one-way and additive: old builds ignore the unknown section (they cannot use knowledge bases), and old backups simply yield no bases — no migration, no LWW key.
5. **Deletion has no tombstone**: deleting a document or base is a local physical delete, following the skills precedent (a LAN peer may resurrect it). Trash/tombstone protocol is deferred until user evidence demands it.

## Considered Options

- **Chunks as source of truth (proposal shape)**: rejected — changing chunk parameters would require re-picking the original file, which may no longer exist (mobile file pickers hand out temp paths).
- **No backup participation**: rejected — silent user-data loss on device migration.
- **Typed join table for bindings**: rejected — FK cascade elegance does not pay for a new backup/LAN/clear surface; stale IDs are ignored at read time and cleaned on base delete.
- **Tombstone protocol from v1**: rejected — skills already accept peer resurrection; adding an entity type to `deletion_marker_rows` for v1 is disproportionate.

## Consequences

- The database holds roughly two copies of the corpus text (document + chunks) plus the FTS index; acceptable for personal knowledge bases, with storage accounting as a follow-up.
- Restore correctness depends on chunker determinism; a future chunker change may produce different chunks when an old backup is restored — accepted, since chunks are declared derived.
- The v2 vector backup decision (ship base64 vectors vs re-embed after restore) is deliberately left open; the stable chunk identity keeps either path additive.
