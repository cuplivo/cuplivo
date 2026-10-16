# ADR-0007: A widget-agnostic Markdown IR, and mapping a selection onto it

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

Selecting rendered text in an assistant reply and copying it yields flattened plain text. The markdown
that produced the rendering is what a user often wants to paste elsewhere, and it is not recoverable
from the rendered widgets. `feat/direct-select-text-v4` shipped the v3 answer — **naive subsequence
matching** (its own ADR-0007, to be renumbered on rebase): treat the selection as a subsequence of the
source and return the tightest matching span. It works until the selection crosses a formatting
boundary. Selecting `Hello, world` out of `**Hello**, world` returns `Hello**, world`: the tightest span
that contains the query as a subsequence starts after the opening `**` and ends at the `d`, so the
closing delimiter rides along with nothing to close. The matcher is not wrong about what it was asked;
the model has no structure, so it cannot know that `**` is one node's closing marker.

That same walk of structural knowledge is already spread thin, and a previous commit had to unify it:
`markdown_line_lexer.dart` exists because "streaming blocks, display math, fences, and Details each
walked the same text with different rules" (500f416d2), and it re-derives the renderer's fence, details
and math pairing by hand so the splitter, the details extractor and the trailing-separator classifier
cannot drift. Adding a sixth hand-written structural consumer for copying would repeat the disease.

A third consumer is plausible but not built here: a pure-Dart `pdf` writer could export a conversation
without a webview, which image export (slow, large) and plain markdown (poor on a phone) both fail at.

## Decisions

1. **The IR is the product of the renderer's own walk, not a second parse.** `MarkdownComponent.walkNodes`
   runs the same combined pattern over the same component list and recurses exactly where
   `generate()` recurses; the grammar stays in the components, so a rule change reaches both paths or
   neither. `generate()` is untouched, and `MdWidget`'s streaming fast paths keep consuming
   `List<InlineSpan>` as before.
2. **A component declares its own node** through `MdNode.node(ctx, text)`. The default is a content leaf
   (the element re-emits the source it claimed); a component whose rendering shows something other than
   its source overrides it. The app's replaced components declare theirs too, which is why `node()` is a
   virtual method and not a table of type tests. **A component that overrides `span` or `build` must
   override `node` as well**: an inherited description belongs to the ancestor's rendering. The table
   subclass is what proved it — it renders through a table that owns its own selection area, while the
   base class declares its cells as display text, and inheriting that would have claimed a copy the
   framework never makes.
3. **Display text is owned by the node, and it is the contract.** A node's display text is what a
   selection sees: the source slice for content, the declared `selectedText` for a widget that
   announces one (math), nothing for a painted line or a disabled container, a `decoration` for text the
   source lacks (an ordered list's number), and a `gap` for a node that contributes no display text but
   still paints, and must re-emit when a selection spans it (an image, an inline formula, a rule, a fenced
   code body). Components whose display text is not their source are emitted whole, because a cut inside
   them cannot be resolved.
4. **The selection is mapped by text, not by framework offsets.** `RenderParagraph` splits its
   selectables on widget placeholders and never copies them, while `SelectableAdapter` reports one unit
   of length and copies its whole declared text — so the offset space a `TextSelection` uses is not the
   space the clipboard gets. Text is the one thing both sides agree on. Normalization (CRLF folding,
   folded newline runs, the invisible characters the renderer inserts) therefore runs over the whole
   concatenation on both sides, never per item.
5. **Structure-faithful completion.** A node the selection cut re-emits its own markers around the
   covered text (`**lo**, wor`), a block re-emits its structural marker (`- `, `### `), and separators
   are never synthesized — the newlines between blocks are source text and are covered items themselves.
   A miss returns `null` and the caller falls back to sanitized plain text, so the action is never worse
   than a copy. `subsequenceMatch` is deleted rather than kept as a second fallback: it would fire
   exactly in the unmodelled cases that are the bug. Which text *is* a span is the surface component's
   rule, and for a code span that rule is the app's escape convention: a backslash escapes the **opener**
   only — `` \`code\` `` is a literal backtick drawn by `BackslashEscapeMd` — because a code span has no
   escapes, so `` `D:\ComfyUI\` `` is one span whose closer is the backslash-preceded backtick (#544).
6. **PDF only constrains the design.** The IR imports nothing, so a `pdf` emitter can walk it later.
   Export itself is a separate feature with its own decisions (CJK font subsetting, rasterizing
   formulas, pagination) and is not built here.
7. **State that changes what a selection can reach is an input to the document build, not something
   the parse infers.** A collapsed `<details>` block never builds its body, so the body contributes no
   copied text; an open one's body is ordinary selectable rich text. The same source therefore has two
   different display spaces, and only the widget knows which one is on screen. The surface keeps a
   `MarkdownDetailsExpansion` record, the details widget reads its initial state from it and writes
   every toggle back (keyed by the block's own source, so a block recycled by viewport virtualization
   resumes its state), and the copy mapping is handed the same record. A block with no record follows
   its own `open` attribute, which is why the record answers with a nullable state rather than a bool.
8. **A drift guard is the proof, and it is permanent.** A widget test selects everything in a rendered
   surface and asserts the copied text equals the IR's display space, per component family. A component
   whose display text drifts from what it renders turns that red instead of quietly mis-mapping a
   selection. Building it found five real drifts on the first runs: ordered list numbers are rendered
   text, a fenced code body is selectable only inside its own area, a collapsed details block copies its
   summary alone, normalization must fold across item boundaries, and an *expanded* details block copies
   its body — the case that forced decision 7.

## Consequences

- The copy action's menu item and hotkey (the branch's other work) map onto `MdDocument` instead of
  `subsequenceMatch`; `SelectionMarkdownMemory` keeps capturing `(source, selectedText)` by value.
- Known limits, each a documented degrade rather than a silent wrong answer: a selection that repeats
  inside one bubble resolves to the first occurrence (the offset-proximity upgrade is deferred, as the
  branch's ADR recorded); a quote re-emits whole (its rendered text drops the `>` per line, so a partial
  re-emission could not put the markers back); a code block and a table contribute no display text at
  all, because each owns its selection — the code view's body and the table's cells are reached through
  their own areas, never through the text around them (measured on all five platforms, which is what
  turned the table's cell-level description into a gap: a selection spanning either one re-emits the
  whole block through the gap path instead).
- `MarkdownDetailsBlock` now carries the block's own source, because the walk consumes a placeholder
  token for it and the token must never reach the clipboard.
- Component assembly moved out of `build()` into `markdownComponentsFor()`, so the renderer and the IR
  walk cannot disagree about which components are in play; the app's component set is now one value
  rather than two lists assembled in a build method. The code-span rule above is what that buys: one
  component rule reaches the renderer, this walk's copy mapping and the streaming splitter together
  (ADR-0008), and the #544 fix is that rule's closer lookbehind no longer reading a backslash as an
  escape. Its guards are the two reported shapes, a `$` span behind a span that ends in a backslash
  (where the preprocessor's mask and the walk must claim the same span), a drift fixture pinning that a
  trailing-backslash chip re-emits its delimiters when copied, and the escape-literal rule.
- The enumerated-heading zero-width mask is retired. `AtxHeadingMd` used to write U+200C between a
  list-shaped prefix and the rest of a heading body because it walked that body with the **global**
  components, where `OrderedList` (behind `BlockMd`'s `^\ *?` prefix) claimed the body of `## 1. 引言` as
  a list item. The mask was written into the source *before* the walk, so the IR could not tell it from
  content: it sat inside the node's range, reached the display space and the re-emitted markdown, and
  only a character-level strip could remove it — the same strip that would have removed a ZWNJ that
  Persian, Arabic and Urdu spell with. A heading body is inline content, so it is walked with the inline
  components now and nothing inserts U+200C; quote and `<details>` bodies keep the document walk
  (ADR-0008 decision 3), where a nested list is real content. `stripRendererInsertedCharacters`
  therefore removes U+200B alone.
- The streaming infrastructure (`IncrementalMarkdownDocument`, `markdown_line_lexer.dart`,
  `MarkdownSourceScan`) is deliberately untouched: it is finely tuned and heavily tested, and
  re-deriving block splitting from the IR is a separate question with its own risk.

## Not in scope

- Migrating the block splitter or the line lexer onto the IR.
- PDF export.
- Offsets as a proximity hint for repeated text.
- Quote, reply-with-quote and speak-selection.
- CommonMark's code-span doubling rule (`` `` `x` `` `` is one span) and the chat API's fence widening:
  both belong to the single code-identification engine of the archived 3.x line (#561 / ADR-0042), which
  this baseline does not carry. Two consequences were read out of the code and are recorded as
  **unreproduced**: the preprocessor's `$` mask matches single-backtick spans only, so a `$` inside a
  multi-backtick span is protected by the mask and claimed by no chip — the placeholder reaches the text
  — and the anchored classifier's `dotAll: false` cannot see an inline-code element that spans lines, so
  such an element is dropped.
- Any further change to what the renderer inserts: the U+200B soft break stays, and stripping it is the
  clipboard's job (ADR-0009 decision 4).
