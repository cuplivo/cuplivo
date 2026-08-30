# ADR-0048: Backup v2 — JSONL chat streams + LWW preference merge

Restore of large backups OOMs because `_restoreFromBackupFile` decodes the entire `chats.json` blob into memory, and preference merge decided conflicts by fill-absent/per-id rules with no notion of which copy is newer. v2 moves chats payload to JSONL streams (identified by a `chats_meta.json` sentinel) and adds per-key LWW via a `settings_meta.json` updatedAt companion; old zips and old builds remain compatible.

## Considered Options

- **Streaming parse of same format** (took JSONL instead): `package:json` SAX avoids the decode but the `.toList()`/byConv accumulation remains — half the OOM problem solved.
- **Whole-blob LWW for all keys** (took key-level LWW + per-id refinement instead): a newer `provider_configs_v1` blob would wholesale replace local configs — silently destroys the #512 provider-proxy local-wins rule and per-id dedupe merges.
- **Per-entity LWW** (rejected): needs per-entity updated_at, which the KV-only design does not have (one updated_at per key blob).
- **Write both formats per zip** (rejected): doubles export/restore cost; incremental backup still forces merge and benefits from JSONL.
- **Per-row restores**: reject (transaction-per-message restore).

## Consequences

- Old builds restoring new zips: restore is destructive only on manual overwrite mode (`clearAllData` + absent `chats.json`); LAN sync / incremental zips force merge (ID-skip, non-destructive). Accepted and documented, no mitigation possible without changing old-build code.
- Structured preference keys keep TODAY's merge functions as refinement over the LWW base — the merge code is not replaced, only its base selection changes.
- Chat merge remains ID-skip (NOT LWW) — messages are append-only; edited versions preserve the existing conflict semantics.
