# ADR-0064: Knowledge Base Retrieval — FTS5 First, Vector Staged (知识库检索架构)

Issue #389 proposed a semantic RAG knowledge base built on `sqlite-vec`, assuming the embedding request chain and backup integration already existed. Codebase reconnaissance found both assumptions false: there is zero `/embeddings` implementation (`ModelType.embedding` is UI grouping only), and backups never copy the SQLite file — every table is serialized explicitly through JSON/JSONL. Committing to the full proposal in one step would couple a greenfield embedding client, a per-platform SQLite source build, and a backup-format change into a single risky delivery. This ADR records the staged architecture.

Status: accepted

## Decision

1. **Knowledge Base is a separate domain object** from WorldBook: `KnowledgeBase → KnowledgeDocument → KnowledgeChunk`. A WorldBook triggers authored entries by keyword/regex at fixed positions; a Knowledge Base retrieves imported document chunks by relevance. Extending `WorldBookEntry` with document/vector semantics is rejected.
2. **v1 retrieval backend is FTS5**, already compiled into the bundled SQLite: ONE global FTS table partitioned by a `kb_id` column, CJK via the `trigram` tokenizer, global bm25 ranking, assistant-level "max injected chunks" (default 5). Per-base topK and similarity thresholds are omitted — BM25 scores are not comparable across corpora.
3. **v1 trigger is auto-injection only**: the latest user message (markers stripped; attachment-only → skip) is the query, and an `<excerpt source=…>` XML block is appended to that same user message's tail — the ADR-0006 cache-neutral volatile position. The shared injection pipeline (main chat, regenerate/continue, Multi-AI, group chat) plus handoff sub-agents is covered; proactive care is excluded.
4. **The vector backend is an additive v2** (sqlite-vec statically linked into the SQLite code asset via the `package:sqlite3` build hook, plus an embedding HTTP client and a global embedding task-model setting). Chunk IDs are stable, so no v1 schema field is reserved for it and no "mode" switch is pre-planted.

## Considered Options

- **sqlite-vec from the start (the issue's proposal)**: rejected for v1 — requires vendoring and compiling SQLite from source on five platforms and building the embedding client from scratch, while the document-import/injection loop is itself unproven. Both hard pieces are independent of FTS5 and can land later behind an unchanged chunk schema.
- **Model-facing `search_knowledge` tool**: rejected for v1 — retrieval silently fails on models without tool-calling; Memory's `injection | tool` dual mode is a mature-feature pattern, not a v1 template. A tool mode is a v2 candidate.
- **Injecting into the system prompt**: rejected — per-turn content changes would invalidate the cached prompt prefix every request; the user-message tail is the established volatile slot (ADR-0006).
- **Hybrid FTS5 + vector RRF from day one**: rejected — doubles ranking complexity before either backend is validated.

## Consequences

- The feature works for users with no embedding-capable provider and offline; its capability must be described honestly as keyword retrieval, not semantic understanding.
- Injected chunks are ephemeral (never persisted), consistent with Memory/WorldBook injection; the LivePanel hit pill is session-scoped, and durable in-bubble citations would need per-message request metadata (ADR-0033) later.
- Regenerate/continue re-runs retrieval over the same last user message; with an unchanged index the result is stable in practice, so no retrieval snapshot is persisted.
- Short-query handling (queries the `trigram` tokenizer cannot index, e.g. 2-character CJK terms) lives inside the lexical channel — query normalization plus a `LIKE` fallback over the candidate `kb_id` set — not in the injection layer. v2 keeps the lexical channel both as the offline/no-provider fallback and as the lexical arm of hybrid retrieval, so this code is reused rather than discarded; no pluggable backend registry is pre-planted (v2 wires the vector arm additively).
- v2 vector work is additive: a new virtual table keyed by chunk id, an embedding client, a task-model setting, and its own backup/rebuild decision.
