# ADR-0040: Semantic Color Migration (Phase 2 of the Theme System)

Phase 2 of #300 lands `AppSemanticColors`, derives the M3 `surfaceContainer*` roles from the
active scheme, and migrates the hardcoded surface-fill / card / status / text-muted colors
across the app to semantic tokens. It completes the phase-2 scope deferred by ADR-0038.

## Context

ADR-0038 shipped custom themes but deliberately deferred `AppSemanticColors` (a ~100-file
migration) and the derived `surfaceContainer*` roles. The app still scattered hardcoded color
literals — `Colors.white10/white12` + `Color(0xFFF2F3F5/F7F7F9)` for subtle fills,
`Colors.white`@0.96 / `Color(0xFF1C1C1E/141414)` for cards, `Colors.black54/white70` for muted
text, `Colors.green/orange/red` for status — so custom themes did not fully recolor the UI. M3
`surfaceContainer*` roles sat at their static purple-tinted defaults, clashing with non-purple
palettes.

## Decisions

- **Port `AppSemanticColors` verbatim from upstream Kelivo.** A `ThemeExtension` with
  `surfaceFill`, `surfaceCard`, `success`/`warning` (+ containers), `searchHighlight`, and
  `chartSeries`, all derived from or harmonized with the active `ColorScheme`; read via
  `context.appColors` (falls back to deriving from the ambient scheme when the extension is
  absent, e.g. plain-`MaterialApp` widget tests).
- **Dark `surfaceFill` alpha is 0.16** — the actual upstream code value (#300's "暗色 surfaceFill
  调亮"). Upstream's doc comment says 0.14 but the code says 0.16; we port behavior, not the stale
  comment.
- **Derive `surfaceContainerLowest → Highest` from the scheme surface** in all four theme
  builders (`_withDerivedSurfaceContainers`), including the post-fix upstream values (light
  `surfaceContainerHigh` = white@0.85 so chat bubbles/cards/menus stay ≈white). This changes ~46
  existing `surfaceContainer*` usages from purple-tinted M3 defaults to palette-derived neutrals
  — the widest single visual change in this phase, and the point of the ADR-0038 "surfaceContainer
  推导" item.
- **Migrate the idiom families to tokens.** `F2F3F5`/`F7F7F9`/`white10`/`white12` →
  `surfaceFill` (the two near-identical light grays collapse into one derived value — deliberate
  value drift); `white@0.96` + `1C1C1E`/`141414` raised surfaces → `surfaceCard`; `black54`/
  `white70`/`grey.shade600` → `onSurfaceVariant`, `black87`/white text → `onSurface`; hover/state
  overlays → `onSurface` alpha; `barrierColor` black → `cs.scrim`; **red danger → `cs.error`**
  (accepted: `cs.error` is pure black in the monochrome palette, matching upstream); green/orange
  status → `success`/`warning` + containers; gold search tint → `searchHighlight`; stats chart
  ramps and the request-log role colors → `chartSeries`.
- **AppBarTheme foreground/title/icon → `scheme.onSurface`** (was hardcoded black/white), and
  `dialogTheme: DialogThemeData(surface)` added to the two non-`ForScheme` builders for parity.
- **No permanent CI color gate.** Upstream added `tool/check_colors.sh`, then removed it two
  commits later as "one-off migration verification tooling" after zero-hardcoded-color strictness
  caused regressions (grayish bubbles, monochrome black/white checkbox borders). We ship
  `tool/check_colors.py` as a one-off local verification script and keep the
  `color-gate: ignore` inline-marker convention for deliberate fixed colors (Cupertino greys,
  avatar tints, contrast-on-primary, `lib/theme/**`). It is NOT wired into CI.
- **`log_viewer` role colors centralize into `chartSeries`** (system/user/assistant/tool =
  indices 6/0/5/3) — the values were already byte-identical; one categorical ramp now serves both
  stats charts and request-log roles.

## Consequences

- Custom themes now recolor the surfaces/cards/status the phase-1 system could not reach; the
  remaining deliberate fixed colors are explicit via `color-gate: ignore` markers.
- Dark-mode subtle fills render lighter (0.16 alpha) than the historical `white10` — the #300
  "调亮" item.
- Red destructive text follows `cs.error`, which is pure black in the monochrome palette
  (accepted, upstream parity).
- The static-palette `surfaceContainer*` rendering changes from purple-tinted to neutral
  palette-derived; the `_withDerivedSurfaceContainers` comment documents the bubble ≈white rule.
- Phase 2 is complete; ADR-0038's "Phase 2 remains a standalone, independently reviewable change"
  note is resolved.
