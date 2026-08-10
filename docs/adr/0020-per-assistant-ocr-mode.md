# ADR-0020: Per-Assistant OCR Mode Replacing the Global OCR Toggle

The global `ocr_enabled_v1` boolean is replaced by a per-assistant tri-state
`Assistant.ocrMode` (`auto` / `always` / `never`, SQLite `assistant_rows.ocr_mode`,
default `auto`), because the old toggle OCR'd images even for vision-capable
models with no way to opt out per model or per assistant. The decision is bound
to the assistant (like `docxMode`/`pdfMode`/`otherOfficeMode`) while the OCR
model/prompt config stays global; the resolved boolean is computed by the single
`resolveOcrActive()` helper in `ocr_model_capability.dart` and consumed by the
message builder, generation services and the input-bar warning banner.

## Migration

The one-time data migration mirrors the `assistants_v1` prefs→SQLite precedent:
run in `AssistantProvider._doLoad`, map the legacy key
(`true` → all existing assistants get `auto`, `false` → `never`), write through
`ChatDatabaseRepository.putAssistants`, then remove the key. The key removal
happens only after a successful write — on failure the key is retained and the
mapping is retried on the next launch. `data_sync.dart` restore captures
`ocr_enabled_v1` (never writing it back to prefs, so the in-place migration can
never re-run over user per-assistant choices) and applies the same mapping to
restored pre-v15 assistants that lack an `ocrMode` field — keeping restore
semantics identical to an in-place upgrade for legacy OCR-off users, instead of
leaving them at the `auto` default. v15-format backups carry per-assistant
`ocrMode` and no legacy key, so they restore untouched.

Why `auto` (智能识别) is the default and the migration target for legacy `true`:
it restores the issue's stated intent (vision models get raw images) and, when
no OCR model is configured, `auto` degrades to exactly the legacy `never`
behavior (raw send / discard), so no user silently starts paying OCR tokens.

## Considered Options

1. **Global tri-state instead of per-assistant.** Rejected: the issue mandates
   assistant binding, and doc-file modes already set the per-assistant
   precedent; a global setting cannot express "this assistant OCRs, that one
   doesn't" in a group where each speaker uses its own mode.
2. **Per-assistant field with global fallback.** Rejected: dual state, dual
   truth — exactly what AGENTS.md §7 forbids. One source of truth is the
   assistant row.
3. **Migration inside the DB onUpgrade.** Rejected: `AppDatabase` has no
   SharedPreferences access; threading the value through `main()` →
   `ChatService` → repository adds plumbing for no benefit, while the provider
   layer already owns the prefs↔assistants transition (assistants_v1 precedent).

## Consequences

- Group-chat speakers each apply their own `ocrMode` automatically (per-speaker
  pipeline); the Director never receives images and is unaffected. The document
  processing panel's OCR section is inert in group chats (no `currentAssistant`),
  consistent with the existing docx/pdf sections.
- `never`/`auto`-without-OCR-model resolves to `ocrActive=false`; images are
  then sent raw to vision models or stripped upstream for text-only models —
  identical to the legacy `ocrEnabled=false` path.
