# ADR-0011: What the compression readout counts

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

The compress dialog's keep-N mode is the one place where a user decides how much of a conversation to
trade away. Until now its only feedback was a sentence — "Summarize 108,700 chars, keep 18,300 chars
verbatim → about 9,720–16,960 tokens (original about 42,300 tokens)" — which buried the two facts a
user is actually deciding between (what this costs now, what it costs after) in a line of prose, and
counted the wrong quantity while doing it: the estimate was built from message **bodies** only.

Bodies are the smaller half of a working conversation. A tool-heavy turn — a file read, a command's
output, a search result — carries the model-visible text in its tool call and tool result, neither of
which the old estimate ever looked at, so the number it reported could be wrong by an order of
magnitude exactly where compressing matters most. The same text was also the only source for the
kept/summarized split, which it cut by character share.

Three decisions follow, each recorded with what it costs.

## Decisions

1. **The denominator is the message list the compression walks, not the context-usage snapshot.**
   The snapshot's history bucket is the natural-looking reuse — it already counts tool results, and
   the progress bar displays it — but it covers only the *in-context* slice: it is bounded by the
   conversation's clear-context boundary and by the assistant's context-message limit, and it can be
   `none` / `computing` / `stale` when the dialog opens. A compression walks the whole conversation,
   so reusing that bucket would under-report the compressed mass in exactly the long conversations
   the feature exists for. The weights are therefore computed for the same `collapsedMessages` list
   the compression itself consumes, which makes the preview and the outcome the same measurement.

2. **Tool calls and tool results count toward the estimate, and never toward the request.** A
   request stays body-only (`conversationLineForCompression`), so counting tool payloads adds no
   tokens to any request, no cost, and no failure mode: the estimate describes the conversation, the
   request describes what the summarizer reads. The asymmetry is deliberate, and it is the one thing
   in this record a future reader is most likely to mistake for an oversight. Reasoning is not
   counted either — it is not part of the kept conversation in general, and the question this readout
   answers is about the conversation, not about one turn's thinking.

3. **The kept/summarized split is a token sum, not a character ratio.** A character ratio assumes
   both spans carry the same chars-per-token density, and the keep-N cut is precisely where densities
   part company. Measured on the ported tokenx estimator (`lib/core/utils/token_estimator.dart`):
   Chinese runs at `_hanziCharsPerToken = 1.15`, plain ASCII at `_defaultCharsPerToken = 7`,
   digit runs at 3 and punctuation runs at 6 — so 115 Chinese characters and 700 ASCII letters both
   cost ≈100 tokens. A kept tail holding a tool result is 4–7 chars/token while the prose head is
   ≈1.15, and a character split reports that tail as several times larger than it is. Both ends of
   the split are already counted per message, so the sum is free; a character-based fallback survives
   only for text that cannot be tokenized at all (1.6 chars/token).

4. **One readable percentage, one honest band.** The reduction is reported as the band's midpoint —
   `−68%` — because `−60%~−77%` puts a minus sign and a tilde in the same token and reads as noise.
   The token band stays as a band on the right-hand side, which is where the genuine uncertainty
   lives: the summary's length is an assumption (10%–30% of the summarized span), and only the
   percentage is allowed to average it away. The layout mirrors the image editor's 节省 row (two
   stacked sides, change over the arrow) so the pattern is one the app already teaches.

5. **Counting runs in one `compute` batch, before the dialog opens.** The weights are built once for
   the whole conversation, so changing the keep count re-sums integers instead of tokenizing text on
   a keystroke. `compute` rather than a raw `Isolate.run`, because web is a build target and there
   `compute` degrades to an inline call instead of throwing — the rule this repo already records in
   the log viewer. A batch that fails falls back to 1.6 chars/token, so the readout never vanishes.

## Consequences

- The dialog reads `共 12 轮 / ~42.3k token → −68% → 3 轮 + 摘要 / ~9.7k–16.9k token`, and the round
  total the user needs in order to choose N arrives with it — the separate "keep 3 of 12 rounds" line
  the first draft carried is redundant and gone.
- Numbers are estimates of the conversation as the model sees it. They do not predict the summary's
  size beyond the band, and the dialog never presents a tighter number than the midpoint.
- For tool-heavy conversations the readout is *much* larger than the old sentence reported. That is
  the correction, not a regression: the old number was measuring the wrong text.
- `estimateCompressionTokens` and `buildConversationTextForCompression` are deleted rather than kept
  beside the new path; `CompressContextWeights` (per-message weights) and `CompressContextSplit`
  (totals, band, reduction) replace them, and `keepRecentStartIndex` is now the single owner of the
  keep boundary that `selectKeepRecentMessages` also reads.
- A round count that covers every round shows its own message instead of a readout, and an unusable
  count shows nothing until submit — there is no state in which the dialog reports a compression it
  will refuse to perform.

## Not in scope

- Sending tool results to the summarizer. The summary still sees bodies only; carrying tool payloads
  into a request is a cost and failure-mode decision (chunking, retries, context length) that this
  record deliberately leaves where it is.
- Counting reasoning tokens, and reviving the image-style savings *bar*: the readout's two numbers and
  its percentage are the whole presentation.
