# ADR-0030: Live Panel Generalizes the Subagent Panel; Download Progress in a Separate Store

The handoff-only 子代理面板 (`SubagentPanel`) becomes the **LivePanel**, a unified
conversation-scoped status surface above the input bar hosting four entry kinds
(subagent job, download job, info pill, warning pill). Download progress is tracked in
a new root `DownloadProgressStore` rather than the `GenerationEngine` slot store, and
stopping the generation force-closes an in-flight download's raw `HttpClient`.

## Context

`SubagentPanel` pinned wait-mode handoff jobs above the parent input bar (ADR-0026). The
workspace `download(url, path)` local tool (`WorkspaceDownloadService`) had no progress
surface, and the image-mode / image-warning pills were floating overlays inside
`_ChatInputBarState`. Issue #307 unifies these into one design language.

## Decisions

- **LivePanel + live entries**: generalize `SubagentPanel` into a single surface; the
  four entry kinds share one pill↔card shell. All entries are conversation-scoped
  (`currentConversationId`) — navigating away hides download progress, mirroring
  subagent behavior.
- **Separate `DownloadProgressStore`**: download jobs live in their own root store, not
  the engine's slot store. The engine owns sub-generation slots (its `requestId`
  CancelToken and `waitSlotsFor` index); a download is a tool-handler job with a
  different lifecycle (no per-entry cancel, no approval auto-expand). Reusing the engine
  store would couple a filesystem tool to the generation pipeline. The ADR-0026 "live
  store" shape is honored (handler awaits, UI watches the store) but instantiated
  separately.
- **`InputStatusProvider`**: pill state (image-mode / image-warning keys, dismissals,
  has-images) is lifted out of `_ChatInputBarState` into a root provider — the single
  source of truth for both pill display and the input bar's image-routing behavior.
- **No per-entry ✕ on downloads**: the user stops the conversation to cancel. This
  requires threading a cancel signal into `WorkspaceDownloadService.download`, whose raw
  `HttpClient` is independent of the Dio `CancelToken` used to cancel the generation.
  Without the abort, the download would orphan and still install the file after
  cancellation (silent completion).

## Consequences

- `SubagentPanel` is renamed `LivePanel`; the subagent entry's behavior (✕ cancel,
  approval/ask_user auto-expand, tool-call card takeover) is unchanged.
- `WorkspaceDownloadService.download` gains an `onProgress` (bytes + total) and a cancel
  signal; `WorkspaceToolsService.tryHandleToolCall` and `ToolHandlerService` thread the
  conversation id, tool-call id, and progress sink through.
- The download pill has no ✕ — the only cancel path is stopping the whole generation
  (which now also aborts the raw client).
