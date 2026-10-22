# Markstream delta audit — the four dropped Markdown units

The 4.4 re-base replaced `gpt_markdown` and Cuplivo's own Markdown IR with
upstream's `markstream` package. Per [ADR-0004](adr/0004-follow-upstream-rebase.md)
and the runbook's rules 7-8, the four units that built the IR (#1015, #1017,
#1019, #1020) were **dropped as patches** rather than replayed: upstream built
the same capability in `dependencies/markstream`, and keeping two mechanisms for
one behaviour is how a fork rots.

This document is the audit the runbook asks for: every user-visible behaviour
those units carried, and where it lives now. Verdicts are one of

- **absorbed** — markstream (or the app-side host under `lib/shared/markdown/`)
  already provides it; nothing to port;
- **absorbed, uncovered** — provided, but no test pinned it; a regression test is
  added here;
- **gap** — not provided; ported as a markstream-native change.

## #1017 — "one walk, one pipeline" (rendering, streaming split and copy share one IR)

| behaviour | where it lives now | verdict |
| --- | --- | --- |
| One parse feeds static rendering | `markstream/lib/src/core/parser/*` → `flutter/render/*` | absorbed |
| Streaming re-parse with block identity kept stable | `core/parser/incremental_document.dart`, `flutter/markstream_view.dart` (`streaming:`, `cullToViewport:`) | absorbed |
| Streaming chunk splitter with stable boundaries (`markdown_streaming_split.dart`, 762 lines) | replaced by the parser's incremental document; no chunker needed | absorbed |
| Line lexer / source scans (`markdown_line_lexer.dart`) | `core/parser/source_line.dart`, `mapped_text.dart` | absorbed |
| Copy shares the same document (no second parse) | `core/serialize/to_markdown.dart`, `to_plain_text.dart`, `core/text_index/text_index.dart`; app menu in `lib/shared/markdown/markdown_actions.dart` | absorbed |
| Perf benches (`test/perf/inline_walk_bench.dart`, `split_cost_bench.dart`) | `markstream/test/perf/*`, `core/performance_limits.dart` | absorbed (replaced) |
| ADR-0007 + ADR-0008 (IR design and unified pipeline) | superseded by this document | retired |

**Verdict: absorbed.** The unit's *decision* — one document, not three walkers —
is the one markstream implements; replaying our IR on top of it would be the
"two implementations of one defect" the runbook's rule 8 forbids.

## #1019 — an inline code span's closer is not backslash-escaped

Behaviour: in `` `a\` `` the code span closes at the backtick that the backslash
precedes, because CommonMark escapes do not apply inside code spans. The old
`gpt_markdown` scanner treated that backtick as escaped and never closed the span.

Evidence in `dependencies/markstream/lib/src/core/parser/inline_parser.dart`:

- the equal-length backtick runs are paired once, up front, by scanning the text
  (`_InlineSession`, lines 162-182) — the pairing never consults escapes for a
  single-backtick run, so the closing run is found regardless of a preceding `\`;
- the code-span branch (lines 364-399) only looks the closer up in that map.

Only runs **longer than one** backtick carry escape handling (lines 174-179),
which is a deliberate accommodation, not the old defect.

**Verdict: absorbed, uncovered.** `test/core/spec/fixtures/commonmark-0.31.2.json`
contains no backslash-plus-backtick example, so nothing would notice a
regression. A regression test is added in
`test/shared/markdown/markdown_inline_code_escape_test.dart`.

## #1015 — copy a rendered selection as Markdown

| behaviour | where it lives now | verdict |
| --- | --- | --- |
| A selection copies as Markdown, round-tripping the source | `SelectableRegion` controller `selectedMarkdown` — `markstream/test/flutter/document_selection_test.dart` (`expect(controller.selectedMarkdown, 'Before \`code\` middle **After**')`) | absorbed |
| Copy-as-Markdown menu entry | `MarkstreamActionKind.copyMarkdown` rendered by `lib/shared/markdown/markdown_actions.dart` | absorbed |
| A table copies as Markdown, and as CSV | `toMarkdown(table)` / `tableToCsv` behind `copyMarkdown` / `copyCsv` actions | absorbed |
| Copy works while streaming | the copy controller reads the incremental document | absorbed |
| Copy a rendered selection as rich HTML | `lib/shared/markdown/rich_clipboard.dart` | absorbed (upstream's own) |

**Verdict: absorbed.**

## #1020 — a table cell and a code body are paragraphs of the surface's owner

| behaviour | where it lives now | verdict |
| --- | --- | --- |
| One selection surface spans details, fenced code and tables | `markstream/test/flutter/document_selection_test.dart:165` builds `Before … <details> … ```dart … ``` … table … After` and selects across all of it | absorbed |
| A table cell joins the selection chain (copy as TSV) | `document_selection_test.dart` + `rich_blocks_test.dart` `tableSource()` | absorbed |
| Code body selectable, no isolated regions | upstream fixes `fab944ddd`, `c7ee19ac8`, `d218c86f2` sit in the baseline; `selectable_span_adapter.dart` | absorbed |
| Selection geometry stays valid when selectables change | `flutter/selection/stable_selection_container.dart`, `selection_edge_initialization.dart` (upstream `cf2af98e6`) | absorbed |

**Verdict: absorbed.**

## What is *not* covered by markstream (still to be re-ported)

| unit | scope | status |
| --- | --- | --- |
| #1014 | hand cursor over links, citations, inline `<a>`, inline images and `<details>` labels; I-beam over surrounding text; an unresolvable workspace image keeps the I-beam | **not carried — asked upstream, see below** |
| #1027 | a reply carries a quote citation (rendered through markstream's citation syntax) plus its hotkey | to be ported |
| #1028 | a PDF laid out from the document AST, no WebView and no second renderer | to be re-laid on markstream's visitor / text index |

## Cursor affordability (#1014) — deferred to upstream

What markstream already has: `flutter/render/inline_builder.dart` sets
`SystemMouseCursors.click` on the span or atom of any tap target (lines 102-125,
127-141, 169-192), the app wires `linkHandler` / `imageBuilder` / the citation
extension in `lib/shared/markdown/markdown_with_code_highlight.dart:50-66`, images
that resolve get their own `MouseRegion(click)` in
`lib/shared/markdown/link_image_handlers.dart`, and an unresolvable image falls back
to `_broken()` with no tap target.

What is missing is the **resolved** cursor inside a selectable surface. Measured on
this baseline (hover a real glyph, read
`RendererBinding.instance.mouseTracker.debugDeviceActiveCursor`):

| surface | expected | measured |
| --- | --- | --- |
| plain text inside `SelectionArea` | I-beam | `text` ✓ |
| `<details>` summary | hand | `text` ✗ |
| link text (span carries `click`) | hand | `text` ✗ |
| broken workspace image | I-beam | `text` ✓ |

Two causes, both in `markstream` itself:

1. `flutter/render/paragraph_run.dart` wraps the selectable run in
   `MouseRegion(cursor: SystemMouseCursors.text)`; a paragraph-wide region cannot
   express per-glyph cursors and wins over the span. Removing it alone is worse:
   paragraphs on the batched (`_RenderParagraphRun`) path then lose the I-beam for
   plain text too (resolves to `null`/`basic`).
2. `flutter/render/blocks/details_block.dart` wraps the summary in a bare
   `GestureDetector` with no `MouseRegion`.

A vendored patch was written and reverted on purpose: the fork's policy is to
re-base on upstream, not to diverge inside `dependencies/markstream` (the same
reasoning as the runbook's "two implementations of one defect"). The fix — a
per-glyph cursor region that hit-tests the pointer position and falls back to
`text`, plus a `MouseRegion(click)` on the details summary — is requested upstream
in [Chevey339/kelivo#1269](https://github.com/Chevey339/kelivo/issues/1269).
When that lands, #1014 is a no-op on the next re-base.

