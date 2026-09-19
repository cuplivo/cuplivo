# Changelog

## 4.0.0+41 — Re-baseline release

Cuplivo v4.0.0 re-bases the fork onto upstream Kelivo `915a8b1d` (v1.2.7+76) by replay — never merge. The upstream foundation (Drift database, schema governance, backup portability) now carries every fork feature. Decision record: `website/docs/adr/0004-v4-rebaseline-upstream.md`.

### Foundation

- Upstream stack as the single mainline; package `Cuplivo`, app id `com.cup11.cuplivo`, artifact contract `Cuplivo_<platform>_<version>_<abi/ext>` unchanged.
- First-run data migration: Hive legacy database migrates to SQLite through schema v1→v6 with pre-migration copy and rollback; the old database is never deleted before migration succeeds.
- Schema v6 (single delivery): message replies (quote), group chat tables, `subgroupId` (multi-AI parallel threads) and `contextTokens` (card token stat).

### Replayed features

- Message replies, group chat, OCR + document understanding, proactive care letters.
- Incremental backup + LAN sync — fully redesigned port of the v3 engine.
- Multi-AI comparison: ≥2 models per round, inline cards with adopt/drop/retry, synthesize mode, schema-backed thread identity.
- World-book groups (backup format), translate visible-language management.
- Utilities: temp-conversation save, input drafts, startup assistant pin, reasoning-effort vocabulary, stats dimension filters, image-generation options, AI log analysis, Markdown subsequence copy, math formula export.

### Accepted losses

- Legacy trash/tombstone data does not migrate.
- LAN sync history resets on v4 (the incremental engine is a full redesign).

### Baseline notes

- Kept-by-design Kelivo residue (interoperability): `kelivo_*` MCP tool names, `@kelivo/*` package refs, `kelivo-file://`, `kelivo_backups` prefix, psycheas.top URLs, backup payload `appName: 'Kelivo'`.
- Pre-existing upstream test failures (17 auth-related + root-environment chmod) remain; the release gate is "no new failures".
