# ADR-0044: Message Selection Unified Entry (消息选择统一入口)

The message 更多/右键 menu offered two actions (分享 / 选择消息) that both entered
the same message selection mode; only the bottom action bar differed
(`ChatSelectionMode.share` vs `delete`). We merged them into one entry and one
unified action bar.

## Decision

`MessageMoreAction.share` is removed. The menu keeps a single entry —
选择消息/Select Messages — which enters selection mode with the anchor message
and its paired user/assistant message pre-selected (the pre-selection that the
share entry used). `ChatSelectionMode` and the `_selectionMode` field are
deleted; selection mode has one shape, and the bottom bar is a unified
`ChatSelectionActionBar`:

- Row 1: TXT / MD / Image / 删除 (destructive, `cs.error`)
- Row 2: Thinking tools / Thinking content toggles

Multi-version selection produces a single radio confirm dialog
(删除本版本 default-selected / 删除全部版本) with the count warning; single-version
selection keeps the existing confirm dialog verbatim. No new ARB keys were
needed. `SelectionToolbarOverlay`, `DesktopSelectionToolbarOverlay`,
`HomePageController.confirmSelection()` and the now-unreferenced
`showChatExportSheet` batch-export path were removed as dead code. The WebView
protocol keeps accepting the legacy `'share'`/`'select'` actions and routes both
to the unified entry.

While selection mode is already active, a legacy `'share'` action now behaves
identically to `'select'`: it toggles the tapped message instead of resetting
the selection (the old `shareMessage` always re-entered selection with the
anchor pre-selected). This is deliberate — the old reset semantics were only
reachable by external protocol callers, and toggling is more useful inside the
selection UI. The bundled WebView never emits `'share'` itself.

## Consequences

- The menu shortens by one row; both quick paths (share the pair, or select then
  delete) survive inside selection mode.
- The `message_more_sheet`, `home_page_controller`, and
  `chat_selection_action_bars` tests were rewritten for the unified bar.
- The fork-divergence boundary vs upstream Kelivo (which keeps separate
  分享/选择消息 entries) is deliberate; see CONTEXT.md 消息选择模式.
