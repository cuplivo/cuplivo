# ADR-0064: Persist thinking-step expand/collapse in the reasoning payload (issue #737)

A reasoning segment's `expanded` flag already rides `reasoningSegmentsJson` (written during generation, restored on load), but user toggles only mutated the in-memory segment — the payload was never rewritten. So a message whose payload arrived with `expanded: true` (e.g. via a WebDAV restore) could never be closed persistently: restart/switch re-read the stale `true`. We persist the manual choice: on a settled message, re-serialize the reasoning payload (segments + the `contentSplits`/`reasoningDetails` the message already had — the same nullable pass-through `chat_actions._flushStreamingProgress` uses) and write it back with `updateMessageSilent`, while restore keeps trusting the persisted flag. Streaming messages are never written — the engine owns live segment state and its periodic flush would overwrite the toggle.

## Considered Options

- **Derive expansion from `autoCollapseThinking` on every load** (rejected): only fixes a stale `true` when the device has Auto-collapse Thinking ON; a device with it OFF reopens, so the reported "cannot stay closed" survives.
- **Device-local store keyed by messageId** (rejected): never syncs, but adds a new local-only key plus a deletion lifecycle, and diverges from the existing payload field.
- **Strip `expanded` from exports** (rejected): more format surface, and the flag legitimately survives a whole-device migration.

## Consequences

- The flag travels in backups and LAN sync like the rest of the payload. Overwrite-restore from another device can still re-expand (existing overwrite semantics); merge restore (ID-skip) preserves local state.
- No schema change or migration: `message_rows.reasoning_segments_json` already exists.
- Incremental backup and LAN sync filter messages by `message.timestamp` / version (`data_sync._incrementalQualifiedMessages`), which `updateMessage`/`updateMessageSilent` do not bump, so a toggle on a version-0 message is carried by a full backup/sync but not by a `since`-filtered incremental exchange.
- One shared `StreamController` entry point (`persistReasoningExpansionIfSettled`, built on `buildReasoningSegmentsJson` + `persistReasoningSegments`) serves both `HomePageController` (mobile/desktop/Multi-AI/web viewport) and group chat; it swaps the `ChatController` list copy and invalidates its grouped/collapsed caches (per `replaceMessage`'s batch-mutation contract) so an in-place re-restore and cached views read the same payload as the database. A persist failure is logged, not thrown.
- Out of scope (unchanged): the legacy plain `reasoningText` fallback keeps its hardcoded `expanded=false` on restore (`restoreMessageUiState`), as does the legacy inline-`<think>` widget-local map. The whole-card toggle reads `ReasoningData.expanded`, which has no persisted counterpart — the payload stores only per-segment flags — so persisting the plain path would require a new payload-level field plus a format/backup change. Its visible gap is also the reverse of #737: restore starts collapsed, so the card cannot get stuck closed, it just cannot stay open.
- Non-list vendor `reasoningDetails` shapes are ignored with a `debugPrint` at capture and never enter the payload; deliberately they do not abort the slot, since the serializer already tolerates values it cannot encode.
