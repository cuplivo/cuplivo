# ADR-0042: Input Bar Buttons Customization (order + direct/in-more)

Issue #282: the input bar's left action row (15 conditional buttons, incl. a
dedicated **customize entry** that always defaults into the More bucket so
users discover the feature from "+") becomes user-customizable in order and in
"direct on the row" vs "stored in the More bucket" (2-state — nothing is ever
fully hidden). One global settings-level config applies to all assistants,
conversations, and platforms; while unset, every platform keeps today's
behavior; the first customization pins an explicit config. The editing UI
follows the assistants pattern (reorder list + `IosSwitch` rows), pushed page
on mobile / centered dialog on desktop.

## Why the config is global, not per-assistant or per-platform

The buttons are UI chrome (camera, context clear, world book), identical for
every assistant — the assistant-parallel (per-assistant tool/MCP/skills
toggles) governs assistant-owned *data*, which these buttons are not. The
issue is a personal habit ("按个人使用习惯调整布局"), not assistant behavior.
Per-platform split was rejected: one shared list, items a platform can't
render (camera on desktop, model select in group chat) are simply skipped —
existing conditionals still win.

## Why one More bucket per platform — and how the desktop "no 更多" resolves

The mobile right "+" (`BottomToolsSheet`) and the tablet/desktop left-end "+"
(anchored menu) are two platforms of the same bucket concept. Desktop's
commentary "不存在'更多'" was about the bottom sheet; the left-end "+" already
exists as width auto-overflow and is extended to always show while the bucket
is non-empty. Deliberately never two "+"s on screen: on the phone, row width
overflow merges into the right sheet (no left "+" on phone); on tablet/desktop
the anchored menu holds in-more items + width overflow, in configured order.

## Why sentinel unset

A naive "default all direct" would change today's phone layout (9 items would
suddenly leave the sheet for the row); "default mobile-style globally" would
regress tablet/desktop (9 buttons bagged on first launch). The config is
effectively "unset" (absent key) until the user customizes once — zero change
for existing users on every platform; the explicit config then applies
globally. Future new button ids append as direct by default.

## Considered and rejected

- **3-state (direct / in-more / fully hidden)**: rejected — fully hidden
  makes buttons unreachable except via the settings page (accidental
  "where's my camera") for no real gain; the issue's "隐藏" reads as
  "收纳到更多".
- **Per-assistant config**: rejected (see above).
- **Per-platform configs**: rejected — two UIs, two merge rules, four test
  surfaces for one feature.
- **Desktop settings pane**: rejected in favor of a centered dialog
  (assistant-edit parity), avoiding a new nav entry for a single row.

## Consequences

- New `SettingsProvider` keys (SharedPreferences, rides `settings.json`
  backup/restore; merge keeps flat scalars "only if absent locally").
- `BottomToolsSheet` becomes dynamic: it needs rows for model search /
  reasoning / quick-phrases / tools too (it currently only has rows for the
  tablet-side 9).
- Phone "custom direct" items (camera/photos/…) require wiring their
  callbacks on phone (currently tablet-gated) once the config is explicit.
