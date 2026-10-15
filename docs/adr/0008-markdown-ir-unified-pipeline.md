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
   inline vocabulary — text, decoration, group, bold, italic, strike, underline, inline code, link —
   into spans, and a component's `span()` becomes `node()` plus that emitter with the component's own
   style. The parsing disappears from `span()`, so the emphasis family, inline code, links and headings
   each decide their text in one place. App variants that differ only in style (`EscapeAwareBoldMd`,
   `EscapeAwareItalicMd`, `EscapeAwareHighlightedTextMd`, `LineSafeLinkMd`) shrink to an `exp` and a
   style hook, which removes the "overrides `span`, inherits `node`" hazard structurally rather than by
   review.
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
   rather than per component.
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

`flutter test test/perf/long_streaming_bench.dart`, medians in µs (p95 in parentheses). The gate for
every phase is ±5% on the same shapes; the numbers are re-recorded in the phase commits.

| shape      | 20           | 200          | 2000         |
| ---------- | ------------ | ------------ | ------------ |
| paragraphs | 6061 (12520) | 6037 (12411) | 7870 (11783) |
| lines      | 3791 (7611)  | 3750 (8141)  | 8516 (16657) |
| single     | 3349 (6320)  | 6421 (8418)  | 6223 (12451) |
| code       | 11939 (19053)| 13503 (20592)| 13270 (18031)|

## Phases and gates

- **A — one traversal.** Private `_walk` with two sinks; `walkNodes` gains an optional element callback
  (the coverage registry uses it). Gate: no contract change, the markdown suite passes unmodified,
  benchmark within ±5%.
- **B — components emit from their node.** `MdSpanEmitter`; the inline families and the heading and
  quote builders inverted; the unreachable `SetextHeadingMd` and `LabelValueLineMd` deleted; the
  package table's row splitting shared between `build` and `node`; the coverage registry added; drift
  fixtures extended per inverted component. Gate: the coverage registry is green (and provably non-
  vacuous), benchmark within ±5%, otherwise phase C's elision is pulled in.
- **C — the streaming path.** Streaming fixtures for unclosed constructs (fence, emphasis, inline math)
  under the streaming component set; the benchmark re-recorded; the degenerate elision only if B
  regressed.
- **D — block splitting.** Splitter goldens ported first (whitespace-bearing blank lines, pending lists,
  indent merging, math-tail protection, CR normalization, append proofs), then the walk-derived
  splitter replaces `IncrementalMarkdownDocument`, `StreamingCodeFenceParser`, the fence `spanBuilder`
  path and the trailing-separator classifier. `MarkdownLineLexer` stays: its other consumers
  (`assistant_paragraph_splitter`, `timeline_visibility`, `diagram_exporter`, details extraction) are
  line classifiers for other features, not renderer mirrors.

## Consequences

- A rule change reaches the renderer, the IR and the splitter through one path or not at all.
- The app keeps overriding components (that is how its styling and widgets work); what it no longer
  overrides is the *parse*. The invariant is "a component whose rendering changes structure declares its
  own node", and the registry makes an omission fail a test rather than a review.
- Deleted by the end: the second traversal (~90 lines), the parsing halves of the inverted components,
  `IncrementalMarkdownDocument` (303), `StreamingCodeFenceParser` (~135), the fence span path and the
  trailing-separator classifier (~120), and two unreachable components.
- The details placeholder rewrite stays. It has a measured history (nonce minting, sibling-fragment
  aliasing) and decision 1 of ADR-0007 still holds: the placeholder keeps a rewritten offset space out
  of the walk. Decision 8 changes keys, not the mechanism.

## Not in scope

- Migrating the line-level heuristics of other features (TTS paragraph splitting, timeline culling,
  diagram export) onto the IR.
- Handing pre-walked nodes into nested block widgets (decision 3).
- PDF export, the copy path's caching, and the `feat/direct-select-text-v4` rebase onto this work.
