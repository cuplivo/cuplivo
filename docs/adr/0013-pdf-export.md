# ADR-0013: PDF export — one walk over the message AST, no WebView and no second renderer

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

Cuplivo 3.x exported a conversation to PDF by rendering the chat surface in a hidden `WebView` and
printing it. 4.0 replaced the renderer with a Markdown IR and #1028 rewrote the export on top of it:
one walk produced a `pdf` document directly, which also moved the layout onto a background isolate
because only bytes and strings cross that boundary.

4.4 then replaced the IR with markstream (`docs/markstream-delta-audit.md`), so the export was re-done
on that tree. The page itself — pagination, fonts, the chrome, line filling, the fake bold — did not
change: what changed is where the nodes come from, and what the export may stop doing because the
grammar now answers questions the IR could not.

Three facts drove this round:

- **The writer is not a typesetter.** `pdf` can only break a `Column` *between* its children, and its
  page guard is an `assert` — so in a release build a block taller than a page does not fail, it hangs.
  Everything the page groups is therefore drawn per block rather than nested, and anything unbreakable
  (a picture, a formula, a table row) is capped at a fraction of the page.
- **A consumer with no widget tree still has to read the same message.** The screen parses with
  `MarkdownParser` + the app's `ParserOptions` + `kelivoInlineSyntaxes`; an export that parsed raw
  source printed `[cite:id]`, link titles and `$$…$$` as markdown.
- **A page is not a screen.** Fonts have to be embedded, one face is all the writer can embed, and a
  page has no hover, no chevron and no clipboard.

## Decisions

1. **The layout walks markstream's AST, not a flattened IR.** `_walkDocument` is
   `MarkdownParser(options, inlineSyntaxes).parse(source)` and the walk dispatches on node types;
   `pdfRasterKeysIn` is the same walk, which is why the keys it names are the drawings the layout asks
   for.
2. **Nesting is the tree's, not the source's.** A list's depth is one step per level, capped at six; a
   quote's body and a `<details>` body are children, so nothing is re-extracted from the source. The
   two source-derived helpers the IR needed (`pdfIndentForSourceLine`, `pdfTaskMarkerOf`) are gone,
   together with the per-line fence/quote/table/detail parsers.
3. **A citation is a node.** The grammar's `kelivo-citation` carries its refs; the number is the cited
   result's place among that message's own search results, which the caller resolves
   (`citation_index.dart`) and both the chip and the page label through `citationLabelOf`.
4. **Every text leaf is a direct child of the page flow.** Grouping is drawn per block (`_BlockSkin`);
   a ruled skin drops its own rounding because the writer refuses a radius beside a non-uniform border.
5. **The page takes its ink from the app's light palette**, guarded against white, because a dark
   theme's primary vanishes into paper — and diagrams are captured with the light scheme too, since a
   bitmap carries its own background.
6. **The walk runs in an isolate.** `buildConversationPdf` is called through `compute`; it may touch no
   `BuildContext`, no bundle and no theme, which is why the two settings it needs arrive as booleans
   (`markdownParserOptionsFor`) and the callout titles arrive as a map (`PdfExportRequest.alertLabels`).
7. **A degrade is reported, not hidden.** A formula with no drawing prints as its TeX, a diagram with
   no bitmap as its code, a picture this device cannot read as its reference — and `PdfExportResult`
   counts each one for the result screen.

## Consequences

- The screen and the page cannot disagree about a message: they share the parser, the inline syntaxes,
  the citation label, the picture-size rule and the diagram rule. Each of those rules is one function
  in `lib/shared/markdown/` or `citation_index.dart`, called from both sides.
- The page follows the *screen* where the old expectations came from another renderer. A `$$…$$` pair
  is a display formula wherever it stands (a short pair is no longer left literal), a task item is read
  from the node rather than from `[x]`, and a bullet is still the ASCII `-` because the writer's
  built-in face throws on U+2022.
- `docs/flaky-tests.md` and `CONTEXT.md` carry the measured figures (leading, gaps, stroke widths,
  raster scales) rather than this ADR: they are the page's rhythm, and a later change that wants to
  move them should see where they were measured.
- Still open, deliberately: a CJK fallback face (a Latin-only pick exports CJK as boxes), line filling
  inside a table cell, and a hanging indent for a marker that is a widget. Each is recorded as a
  limitation in `CONTEXT.md` with the evidence that makes it a limitation.
