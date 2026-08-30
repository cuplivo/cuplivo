# ADR-0047: Markdown code scanner — one rule set for spans and fences

Issue #544 (inline code span around a Windows path `D:\ComfyUI\` rendered
garbled) surfaced a rules-copy problem: five independent implementations of
"what counts as code" existed — the render component regex
(`EscapeAwareHighlightedTextMd`), the details-walker's hiding pairing, the
display-math scanner's fence handling, the streaming line lexer's fence state
(minus the blockquote/list/indent context), and the chat API image extractor's
walk. They had already drifted: the render closer guard `(?<![\\`])` refused
a backtick preceded by a backslash (as if code spans had escapes — CommonMark
says they do not) and swallowed the following sentence.

We now have ONE rule set: `lib/utils/markdown_code_scanner.dart`. It defines
fence marks, escape-aware inline run pairing, span normalization, fence
regions (incl. quote/list contexts, unclosed streaming fences, the "}```"
inline-closing extension, and the info-string-shape list fence), and the
segment types. Despite the "scanner" name it is NOT a resumable streaming
parser: the lexer and the display-math scanner keep their own state machines
and consume the shared primitives, so their behavior is pinned to the same
rules without paying for segmentation on the incremental hot path.

## How the render path consumes it

`_preprocessFences` tokenizes code regions into opaque placeholder tokens
(`\uE020C|F`, id, content-length+FNV hash, `\uE021`). The token text carries
no `` ` ``, `$`, `<`, `[`, `|`, or newline, so every later rewrite (math
normalization, table stabilization, citation flattening, ...) ignores it —
the same protection the old `__CODE_MASK_n__` pass provided. `FencedCodeTokenMd`
and `InlineCodeTokenMd` match the tokens and resolve content from a
`MarkdownCodeRegistry` that ships with the cached tokenized payload.

The embedded content hash is load-bearing: tokenized-text equality implies
code-content equality, so `_CachedMarkdownBlock` identity, `GptMarkdown.data`
change detection, and the streaming rebuild path all refresh when code grows —
without it, growing a mermaid fence leaves `\uE020F0-...-...\uE021` textually
identical and the block never re-renders.

## Deliberate deviations documented in CONTEXT.md

- Escape rule: a backslash-escaped backtick never OPENS a span (the app's
  escape convention; CommonMark would otherwise start a span at `\``), and a
  backslash-preceded backtick still CLOSES ($544). Inside spans no escapes.
- Details walker pairs with `escapeSensitive: false` (wider hiding) so that
  "\`<details>\`"-style documentation prose never becomes a details card.
- Quote fences and list fences (backtick-only, info without whitespace) are
  app extensions ported from the legacy preprocessor; the "}```" inline
  closing moves from a textual rewrite (which could OPEN a fence from prose
  lines outside any fence) into the in-fence closer extension only.
- Span pairing is single-line (multi-line spans stay a documented deviation).
