# ADR-0008: One walk, and one markdown → IR → widget/copy pipeline

**Status:** Accepted (2026-10) — being carried out in four phases (A–D)
**Deciders:** cuplivo
**Supersedes:** ADR-0007 decision 1 ("`generate()` is untouched") and its "Not in scope" entries for
migrating the block splitter and the line lexer onto the IR. Everything else in ADR-0007 stands.

## Context

ADR-0007 gave the project an IR, but placed it *beside* the renderer rather than *under* it:

- The traversal exists twice. `generate()` (97 lines) and `walkNodes()` (82 lines) are one algorithm —
  preprocess handling, component-set selection, `_MarkdownPatterns` construction and eviction, the
  `splitMapJoin` skeleton, the recursion condition, and offset bookkeeping are identical.
- Display text is decided twice. Every component's `span()`/`build()` still re-parses the element it
  matched (`exp.firstMatch`, then `generate(inner)` for the content) while its `node()` describes the
  same thing a second time. 0 of the active components render from their node.
- The block splitter is a fifth hand-written copy of the grammar. `IncrementalMarkdownDocument` splits
  on blank lines and relies on `MarkdownLineLexer` to protect fences, `MarkdownDisplayMathScanner` to
  protect formulas, plus pending-list and indent-merge rules that mirror what the renderer would do with
  the same text. `StreamingCodeFenceParser` re-detects a fence the walk can already claim, and
  `swallowsSeparator` mirrors the `NewLines` gap.

The cost of the second and third copies is not measured in lines: the copies are kept honest only by
tests that compare two implementations, and a rule change has to be made in every copy or none.

The goal is one data flow: `source → (the walk: component exp + node()) → nodes → (emitter / component
builders) → widgets`, with the same tree feeding the selection mapping. The remaining question is the
order and the size of each step, and this ADR fixes both so the work can land in reviewable pieces.

## Decisions

1. **One traversal, parameterized by a sink.** `generate()` and `walkNodes()` become thin wrappers over
   a private walk that pushes what it finds into a `_MdWalkSink<R>`: a render sink builds spans and
   reports their offsets through `onSpan`; a node sink builds `MdNode`s against the walk's source. The
   grammar (the `exp` patterns and the component dispatch) was already shared; the skeleton now is too.
   Offsets are threaded absolutely (source + start), which is the mechanism `walkNodes` already used, so
   the render sink's callback offsets stay exactly what `MdWidget`'s append parser expects. The public
   signatures and the `onSpan` contract do not change.
2. **A text-bearing component renders from its node.** `MdSpanEmitter` (a package part file) turns the
   inline vocabulary — text, decoration, group, bold, italic, strike, underline, inline code, link and
   the image gap — into spans, and a component's `span()` becomes `node()` plus that emitter with the
   component's own styling. `InlineMd`'s default `span` is exactly that pair, so the emphasis family,
   inline code, links and images declare their text once, in `node()`, and the parse leaves `span()`
   entirely. A node the emitter does not describe is handed back to the component set
   (`generate(element)`), which is what re-rendering that element on its own does: that is how formula
   widgets, citation chips, HTML tags and block containers keep their own builders. The consequence is
   an invariant, not a preference — the emitter's handled kinds and the components that render from a
   node are the same set, because a node whose component renders itself would reach the emitter again
   and never return. App variants that differ only in ink shrink to an `exp` plus one hook: the
   `EscapeAware*` family and `LineSafeLinkMd` keep their pattern, `EscapeAwareBoldMd` also declares
   `emphasisWeight`, and the emitter reads that weight from the bold component the configuration renders
   with — the surface declares its emphasis ink where it already declares its components, and a bold
   nested in italic takes the same ink as a top-level one.
3. **Block components that nest block content keep delegating through the whole component set.**
   A details body, a quote's content and a list item can hold fences, tables and lists, which are
   widgets rather than spans; those components re-render their inner text through the same component set
   (`MdWidget` / `GptMarkdown`) while their `node()` walks the same text with the same rules. Handing
   pre-walked child nodes into the child widget was considered and rejected for now: it buys purity, not
   speed (the child already skips reparsing while its text is unchanged), and it would make widget
   retention depend on comparing node trees instead of `String` equality.
4. **Retention stays at the span level; nodes are transient products of the walk.** `MdWidget`'s
   `_plainAppendable`, `_prose` and `_spanGroups` machinery optimizes *output identity* — which spans may
   be reused unchanged — not description. Since the walk produces the spans, the fast paths need no IR
   variant. The escape hatch if node allocation ever shows up in the streaming benchmark is a degenerate
   elision inside the render sink (emit plain elements without materializing a node), in one place
   rather than per component. Phase C measured that hatch instead of assuming it: the node
   materialization phase B added lives inside `InlineMd`'s default `span` — the render sink never builds
   a node itself — and no active inline component has the default content-leaf node, so "emit plain
   elements without a node" would elide nothing. What the one shape that leaned actually does is append
   without parsing at all: its suffix carries no delimiter, so `_plainAppendable` extends the last span
   and the walk is never entered (measured for phase C: one `_parse` for the first frame, none for the
   appends). The hatch therefore stays closed, and a future regression has to show up as a parse-path
   cost rather than as an append cost.
5. **Block splitting is derived from the walk.** A block boundary is a `NewLines` gap node in the
   document walk; fences, details placeholders and closed display formulas are single nodes, so their
   interiors can contain no boundary — which is what the lexer's fence/depth tracking was hand-coding.
   A blank line that carries whitespace produces no `\n\n+` adjacency and therefore no gap, matching the
   current refusal to split there. List continuation and indent merging are decided from the node kinds
   that start each block (falling back to the same line-level list-marker test if a kind is too coarse).
   The one lookahead that stays is an unclosed display-math tail: an unclosed `\[`/`$$` has no node yet,
   so a boundary inside it cannot be committed, and a scanner answers that question alone.
6. **State that changes the display space is an input to the document build; state inside a nested
   selection owner is that owner's business.** ADR-0007 decision 7 already handles the first case. The
   second is closed by construction: a code block, a table, a formula and a diagram each own their
   selection area, so a gap node is the whole of their participation in the outer display space. This is
   why the unified mechanism for "stateful" markdown is one record plus gap nodes, not per-widget state
   plumbing.
7. **A coverage registry keeps the drift guard non-vacuous.** The drift tests prove that copied text
   equals the IR's display space for the components they exercise. A test walks the fixtures with the
   walk's element callback, records which components matched, and fails when an active component matched
   nothing: a new component cannot arrive without a fixture. The registry is the permanent form of the
   one-off "inject a violation, watch it fail" experiment.
8. **Expansion state is keyed by occurrence, not by text.** Two identical `<details>` blocks in one
   reply currently share an expansion key, so opening one opens the other. Under the walk each block has
   a source position, so the record is keyed by the block the walk actually matched.

## Baseline

`flutter test test/perf/long_streaming_bench.dart`, medians in µs (p95 in parentheses), each figure the
median of 25 in-process appends. The gate for every phase is that paired runs show no consistent
regression across shapes; the numbers are re-recorded in the phase commits.

The harness cannot support a percentage gate on this machine. Two runs of the same commit back to back
differ by up to ±40% on a single shape (`single`, `lines`), and one shape can swing 100% while the
others move 10%. A phase's change is therefore judged by interleaving runs of the two revisions — never
by comparing one block of runs against another — and only a difference that holds across shapes is
treated as real.

| shape      | 20           | 200          | 2000         |
| ---------- | ------------ | ------------ | ------------ |
| paragraphs | 6061 (12520) | 6037 (12411) | 7870 (11783) |
| lines      | 3791 (7611)  | 3750 (8141)  | 8516 (16657) |
| single     | 3349 (6320)  | 6421 (8418)  | 6223 (12451) |
| code       | 11939 (19053)| 13503 (20592)| 13270 (18031)|

Phase A, measured with interleaved pairs: the ratios (phase A ÷ before) spanned 0.81–1.44 over the
twelve shapes with a median of +3%, inside the spread described above. That matches what the change
does — it removes one `config.copyWith()` and one span-rebasing closure per recursion and adds one sink
dispatch per matched element — so no direction was expected, and none holds across shapes.

Phase B, same method (run order after, before, after, before, after, after): the three after÷before
pairs spanned 0.76–1.39 with medians of 1.01, 1.09 and 1.05, and 6, 9 and 9 of the twelve shapes landed
above 1.00. A back-to-back pair of the *same* revision spanned 0.66–1.80 (median 1.06), which brackets
the A/B spread, so once more the harness reports no resolvable difference. That is also what the change
predicts: it trades one parse per inverted element (the saving) for one `MdNode` tree with a `MdRange`
per leaf (the cost), and neither dominates a measurement whose noise floor is this high. The one shape
that leans consistently the other way is `single` (one long paragraph, so the append fast path:
+14–29% in all three pairs) — the shape where per-element allocation would show up. Phase C chased that
lead to ground instead of dropping it, and closed it (below).

Phase C re-measured with an instrument that removes the pump entirely:
`test/perf/inline_walk_bench.dart` pumps once for a real `BuildContext`, then calls
`MarkdownComponent.generate` (`walkNodes` beside it as the node-side reference) in a loop, and reports
the median of the per-call times. Two same-revision sweeps of that harness (three shapes × two methods
× two sizes) span 0.84–1.08. Interleaving it against `c27fc9c6a` — three pairs, 1000 elements,
`plain` (a control: it matches no element, so the code path is identical in both revisions),
`emphasis` and `mixed` — resolved no direction: after÷before was 0.92 / 1.07 / 1.10 on `emphasis`,
1.04 / 1.10 / 1.10 on `mixed` and 1.02 / 0.95 / 0.97 on the `plain` control, while `walkNodes` — code
the two revisions share, and therefore the experiment's own drift control — spanned 0.84–1.14 on the
same shapes. The medians-of-three lean 7–8% slower at HEAD on the two shapes that carry inline
elements, which is inside the spread the identical-code control reproduces.

The magnitudes decide it even without the interleave. Inside one run at HEAD, the whole inline walk
over a 1000-element emphasis source costs ~32–35 ms and the same walk over 1000 plain sentences (twice
the characters, no elements) ~14–20 ms. Per sentence that is 17–21 µs more for the two emphasis
elements; dividing by the two elements, and charging the emphasis sentence for its own (shorter) text
at the plain shape's per-character rate, puts one element's entire parse — pattern match, recursion,
node, span, everything — at ~10–14 µs. The append frames the widget benchmark measures on `single` are
3.3–6.4 ms, and phase B added only the node objects to those 10–14 µs. The shape's appends do not reach
the walk at all: its suffix (`'新增输出。'`) has no delimiter from `MdWidget._markdownDelimiter`, so
`_plainAppendable` extends the last span. Probed directly for this phase by printing in `_parse` and in
the fast-path branch, then appending three plain suffixes to a streaming paragraph: one `_parse` for the
initial frame, three fast-path appends, no further parses.

## Phases and gates

- **A — one traversal. Done.** Private `_walk` with two sinks; `walkNodes` gains an optional element
  callback and forwards it into the content walks a component's `node()` starts, so the coverage
  registry can see an element nested in a list item or details body. Gate: no contract change, the
  markdown suite passes, benchmark inside the harness's spread (above).
- **B — components emit from their node. Done.** `MdSpanEmitter` (`md_span_emitter.dart`) plus
  `InlineMd`'s default `span`; the seven inline `span` overrides deleted from the package
  (`HighlightedText`, `BoldMd`, `StrikeMd`, `ItalicMd`, `ATagMd`, `ImageMd`, `UnderLineMd`), with the
  bold component's `emphasisWeight` as the one style hook; `AtxHeadingMd` rendering its body from its
  own node; `ModernBlockQuote` on the shared `markdownQuoteText` (widened to the tabs the app already
  accepted, so the render and the node agree there too); the package table's row splitting shared between
  `build` and `node`; the app's *inline* table component aligned with its global one, which closes the
  last open drift (`**| a | b |\n| - | - |**`); `SetextHeadingMd` and `LabelValueLineMd` deleted with
  their commented-out registration. Gate: the package's own suite (144) and the markdown suite (352)
  pass, both analyzers are clean, and the drift file grew from 16 cases to 28 — twelve new fixtures,
  one per previously unexercised active component, plus the coverage registry over them. The registry was
  shown to fail (naming `StrikeMd`) with one fixture removed and to pass again after a byte-exact
  restore; the emphasis-ink lookup was shown the same way, by hard-coding the weight, which turns the two
  Android weight tests red.
- **C — the streaming path. Done, no production change.** Seven streaming fixtures — unclosed fence,
  closed fence, unclosed emphasis, unclosed dollar math, unclosed display math, a paragraph followed by
  an unclosed fence, and a plain paragraph — assert the copy-equals-display-space equality under
  `streaming: true`, and each asserts that the incremental block list is what rendered it, so a surface
  that silently fell back to the static path cannot satisfy the equality vacuously (shown to fail by
  dropping the flag at the widget call: `MarkdownBlockList` disappeared and the first streaming fixture
  went red). The benchmark question was answered rather than the elision being built: the interleaved
  pairs above resolve no regression, one element's entire parse is ~10–14 µs against 3.3–6.4 ms append
  frames, and the shape that leaned never enters the walk. The conditional elision is
  not justified, so decision 4's escape hatch stays closed and no node-elision variant exists. Gate: the
  drift file's 28 cases became 35, the markdown suite (417 cases over the fourteen markdown files), both
  analyzers and the formatter pass, and the full `flutter test` shows only the eight registered Windows
  failures.
- **D — block splitting. Done.** The goldens moved first — `incremental_markdown_document.dart` became
  `markdown_streaming_split.dart` with no behaviour change at all, so the ported matrix (whitespace-bearing
  blank lines, loose lists, indent merging and reopening, math pairing, CR normalization, append identity,
  scan budgets) was green against the implementation it was written for. The walk-derived splitter then
  replaced that implementation, and **all 54 goldens passed unchanged**: no expectation needed a new
  baseline, so the swap was equivalent *on those 54 inputs* — a claim about the inputs, not about the
  splitter. The review round below is what turned it into a claim about the splitter.

  A boundary is now a bare `\n\n+` run the walk leaves behind. A fence, a table, a closed `<details>` and
  a display formula claim their own element, so the runs inside them are never gaps; a `NewLines` node is
  recognised as the run itself, so it marks a boundary rather than absorbing it; and a run an element
  matches *into* — `---` and `$$` close with `\s*$` — keeps the boundary and drops the separator, which
  is how the trailing-separator classifier and its `_separatorCache` went away. What the walk cannot
  answer stays, with the reason written down: `MarkdownDisplayMathScanner` and the `MarkdownLineLexer`
  details depth veto a run inside an unfinished formula or `<details>` (both are unfinished *prose* to the
  walk), `_listMarker` is the last line-level rule (the list components claim one line each, so a loose
  list's items are separate elements), and an indented continuation still merges upward while an indented
  fence or `<details>` does not — decided only from a complete line, because while that line is still
  arriving it may yet become a fence (the review round below says why that precondition is load-bearing).

  Measuring the splitter, not reasoning about it, found two defects the goldens could not see, and
  `test/perf/split_cost_bench.dart` exists because of them. A run left in place — a list waiting for the
  line after it — can gain newlines from a later append, and committing from part-way into it ended the
  block with the newlines it is supposed to skip; the run's start is walked back now. And the guard that
  decided whether to walk asked about the appended suffix, which is every space and punctuation mark, so
  every frame of English prose re-walked the whole region: 67–110 ms per append on 175 KB. Asking the
  region instead — a boundary is only ever a run, so a region without one has nothing to decide — and
  walking only for the two questions the text cannot answer (is the run inside a claim, did that claim
  match into it) cut the punctuation append to 0.5 ms and a loose list from 87–164 ms to 28 µs. The
  inverse is recorded too: the first boundary after a long paragraph is one frame of 74–106 ms for a
  175 KB region.

  **The review round: the block list is a function of the source.** A review of the landed phase ran the
  deleted implementation beside the new one — a verbatim port of
  `IncrementalMarkdownDocument`, fed the same append prefixes, over a random alphabet of every markdown
  opener (48,000 prefixes) and a 40-source curated corpus (1,081 prefixes). The content was identical
  everywhere: no character lost, doubled or reordered. But 2,573 of the random prefixes produced a
  different block list, and in 77 of them the new splitter froze *fewer* blocks. The difference was not
  in the source: feeding one text in a single `update` produced three blocks, feeding the same text in
  two produced two. **The block list depended on how the reply had been chunked.**

  The cause was the cursor, not the rules. `_decideBoundaries` asks up to four questions whose answer is
  text that has not arrived yet — is the next line an item of the same list, does it continue the
  paragraph above, does the claiming element end exactly where the run does because it is still growing
  — and it then moved the run cursor past the run anyway, so a refusal taken while the deciding line was
  still arriving could never be taken again. What the splitter decides is now stated as an invariant:
  **the visible block list is a function of the source alone** — the same text produces the same blocks
  however the stream delivered it — and a refusal whose proviso is unwritten text is *deferred*
  (`_DeferredRun`, carrying the line-level state as of that run, because the lexer only moves forward)
  instead of settled. Four rules follow from it:

  * A refusal that rests on the line after the run waits for that line's newline: `2` becomes `2)`, and
    `  ` becomes `` ``` ``, so only a complete line can be classified. A complete line that continues a
    list is final, and the block then ends at whatever run arrives after the item.
  * The claim that reaches exactly as far as the run with nothing after it is provisional only while the
    fence it belongs to is still open (`_lexer.fenced`). A rule and a display formula close their pattern
    with `\s*$` and are finished, so the run behind them commits at once with `swallowedBy` set — which
    is what `swallowedBy` is for.
  * The indentation rule kept the deleted implementation's intent but lost its preconditions
    (`_scanCompletedLines` decided on complete lines for the same reason). The merge is decided only from
    a complete line, never when that line opens a fence or a `<details>` — the walk reports an unclosed
    `<details>` as prose, so the line-level lexer answers that case — and a tail that cannot be
    classified yet is **folded into the block above for the returned list only**: the committed blocks
    are untouched, so the tail can still turn out to claim a block of its own.
  * A gap the committed block behind it skipped can gain a whitespace-bearing blank line from a later
    append, and such a line is content to the renderers around it: the boundary is taken again, which is
    the same refusal the whole-source parse makes. Newlines a skipped run gains later belong to that gap
    too, so the tail never starts with them.

  Two goldens moved with the invariant, and in both the *old* expectation was the wrong one: `A\n\n`
  followed by `A\n\n    ` used to keep the committed `A` identical and drop the whitespace tail, a shape
  no whole-source parse produces, and a run that grew after a list wait used to end the block before the
  line that decides it had arrived. The permanent guard is
  `test/shared/widgets/markdown_streaming_split_chunk_test.dart`: a corpus of every construct whose
  boundary the splitter decides, fed one code unit at a time and compared field by field against a fresh
  whole-source update at every prefix, plus explicit goldens for the three chunk shapes the review named.
  The review's own probe came back with 45 boundary-only divergences from the deleted implementation
  (down from 2,573, all `content = 0`) and, decisively, with its streamed and one-shot shapes **equal**.

  The review's second finding was the IR's dead surface, and the answer is deletion: `MdNode.block`
  (whose doc promised a separator rule `MdSelection.emit` refuses), `MdItem.contributesDisplay`, two
  write-only link offsets, the unread `MdDocument.source` and `markdownEndsWithDisplayMath` — which had
  lost its only production caller to this phase — are gone.
  `test/utils/markdown_ir_surface_gate_test.dart` now asks the analyzer's question from the other side,
  because `dart analyze` never reports an unused *public* member and `dependencies/` is outside the
  analyzed roots: every field on a public IR class has to be named outside its declaration, and the list
  is frozen, so a new field has to bring its reader with it.

  The fence fast path went with it. `StreamingCodeFenceParser` re-detected what the walk claims, and the
  walk claims an unclosed fence, so the block reaches the renderer as it stands; the parser, the fence
  `spanBuilder`, `wholeFence` and their test are gone (−188 net). The whitespace contract they pinned is
  unchanged and measured, not assumed: `'```text\nx \n\n'` still shows `x` while the fence is open and
  `'```text\nx \n\n```'` still shows `x `.

  §5.5 was answered by injection: the preprocessor's code masking is **not** redundant now that the walk
  claims fences. Disabled, a fence body's `$5` reaches the code view as `\(5\)` — the math pass runs on
  that text regardless — so the mask stays with its reason recorded where it happens. Its tag half is
  unproven rather than proven: disabling it leaves every markdown test green, so it is kept and recorded
  as such instead of removed on no evidence. Two widget guards (a closed and an unclosed fence body with
  `$` and `<b>`, read from the code view's own text) and the matching drift fixtures fail with the mask
  disabled, which is what makes that answer mean anything.

  §5.4 landed with it: a `<details>` block is keyed by where it starts in the document together with its
  text, so two identical blocks keep their own state and a block that replaced another at the same offset
  starts collapsed. Offsets rather than an ordinal, because that makes the key independent of traversal —
  the surface rewrites block by block, the copy mapping rewrites the whole source, a nested body is
  rewritten by whoever renders its parent, and all three mint the same token for the same block. The
  registry moved from per-block to per-surface and its rewrite cache is bounded; the parity test that
  compares the two traversals caught a real bug on its first run (a cache keyed by text alone returned
  the first place's token to the second place, which is exactly the duplicate case §5.4 is about).

  `MarkdownLineLexer` stays: its other consumers (`assistant_paragraph_splitter`, `timeline_visibility`,
  `diagram_exporter`, details extraction) are line classifiers for other features, not renderer mirrors.
  Gate: the splitter's 59 goldens, the markdown suite (348 cases), both analyzers and the formatter pass;
  the phase's net is +905/−761 including tests. The performance gate for the rest of the work is
  `split_cost_bench` — `long_streaming_bench` cannot resolve a gap: the same revision differs by 20–30%
  run to run (its `lines` shape measured 6.8 ms at 105 KB and 5.9 ms at 175 KB, which is not a linear
  cost), so it is kept for a coarse whole-frame look and not as a threshold.

## Consequences

- A rule change reaches the renderer, the IR and the splitter through one path or not at all.
- The app keeps overriding components (that is how its styling and widgets work); what it no longer
  overrides is the *parse*. The invariant is "a component whose rendering changes structure declares its
  own node", and the registry makes an omission fail a test rather than a review.
- Deleted by the end: the second traversal (~90 lines), the parsing halves of the inverted components,
  `IncrementalMarkdownDocument` (303) and its line scanner, `StreamingCodeFenceParser` (134) with the
  fence span path, the trailing-separator classifier (~120), and two unreachable components.
- The details placeholder rewrite stays. It has a measured history (nonce minting, sibling-fragment
  aliasing) and decision 1 of ADR-0007 still holds: the placeholder keeps a rewritten offset space out
  of the walk. Decision 8 changes keys, not the mechanism.

## Not in scope

- Migrating the line-level heuristics of other features (TTS paragraph splitting, timeline culling,
  diagram export) onto the IR.
- Handing pre-walked nodes into nested block widgets (decision 3).
- PDF export, the copy path's caching, and the `feat/direct-select-text-v4` rebase onto this work.
