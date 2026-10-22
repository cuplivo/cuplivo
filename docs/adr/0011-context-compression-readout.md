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

   Images are counted on the same "what the model sees" rule, at the unknown-size placeholder
   (`kUnknownImageTokens`, 1000) that the context-usage buckets already charge: an attached
   `ImagePart` and each `metadata.mcpResult.imageUris` entry of a tool result. Only the typed
   metadata qualifies, because only it becomes image input — `ToolResultContent` converts it both for
   the turn that just ran and when a later request rebuilds that turn from history — while an older
   envelope's `imageUris` and a result's markdown `![...](path)` line stay text. The markdown line is
   stripped from the weight text for the same reason. A model without image input receives a text
   marker instead and is still charged the image: that errs high, and erring high is the only
   direction this estimate is allowed to be wrong in.

3. **The kept/summarized split is a token sum, not a character ratio.** A character ratio assumes
   both spans carry the same chars-per-token density, and the keep-N cut is precisely where densities
   part company. Measured on the ported tokenx estimator (`lib/core/utils/token_estimator.dart`):
   Chinese runs at `_hanziCharsPerToken = 1.15`, plain ASCII at `_defaultCharsPerToken = 7`,
   digit runs at 3 and punctuation runs at 6 — so 115 Chinese characters and 700 ASCII letters both
   cost ≈100 tokens. A kept tail holding a tool result is 4–7 chars/token while the prose head is
   ≈1.15, and a character split reports that tail as several times larger than it is. Both ends of
   the split are already counted per message, so the sum is free; a character-based fallback survives
   only for text that cannot be tokenized at all (1.6 chars/token).

4. **One readable percentage, one honest band — and the band's base is the text the summarizer
   reads.** The reduction is reported as the band's midpoint — `−68%` — because `−60%~−77%` puts a
   minus sign and a tilde in the same token and reads as noise. The token band stays as a band on the
   right-hand side, which is where the genuine uncertainty lives: the summary's length is an
   assumption (10%–30%) and only the percentage is allowed to average it away. The layout mirrors the
   image editor's 节省 row (two stacked sides, change over the arrow) so the pattern is one the app
   already teaches.

   That 10%–30% is applied to **the summarized span as the summarizer reads it** — body-only tokens —
   not to the tool-inclusive mass that `keptTokens` and `totalTokens` describe. The constants are not
   re-derived here: they come from the body-only implementation this readout replaced, where the base
   was `totalTokens - keptTokens` of bodies (`estimateCompressionTokens` on master). Counting tool
   payloads in the two visible totals is a correction; applying the same fraction to those payloads
   would be a new error, and a summary cannot be longer than the prompt it was generated from. The
   first version of this readout did exactly that and understated the reduction by 7 points for a
   2 KB file read and 15 points for a 200 KB one. Both columns therefore travel together: the model
   weights for `totalTokens`/`keptTokens`, the body-only weights for the band.

5. **Counting runs in one `compute` batch, requested when the readout is first shown.** The weights
   are built once for the whole conversation, so changing the keep count re-sums integers instead of
   tokenizing text on a keystroke. `compute` rather than a raw `Isolate.run`, because web is a build
   target and there `compute` degrades to an inline call instead of throwing — the rule this repo
   already records in the log viewer. A batch that fails falls back to 1.6 chars/token, so the readout
   never vanishes.

   The batch is requested by the dialog the first time it renders a keep-N readout, not before the
   dialog opens. Counting is linear in text volume — measured 0.1 s/MB through
   `estimateCompressContextWeights`, ≈1.8 s for a 16 MB agentic session — and `start` is the default
   mode, which never shows a readout: an eager estimate made every open pay for a number it would not
   display. On web the inline call now happens while the dialog is up, which is the moment the user
   asked for the number by choosing the mode.

## Consequences

- The dialog reads `共 12 轮 / ~42.3k token → −68% → 3 轮 + 摘要 / ~9.7k–16.9k token`, and the round
  total the user needs in order to choose N arrives with it — the separate "keep 3 of 12 rounds" line
  the first draft carried is redundant and gone.
- Numbers are estimates of the conversation as the model sees it. They do not predict the summary's
  size beyond the band, and the dialog never presents a tighter number than the midpoint.
- For tool-heavy conversations the readout is *much* larger than the old sentence reported. That is
  the correction, not a regression: the old number was measuring the wrong text.
- A conversation whose messages carry no tool payloads reads as it did before this record: the two
  weight columns then differ only by the `User: ` / `Assistant: ` prefix of the summarizer's line, a
  couple of tokens per message against a band whose own width is 20% of the summarized span.
- The readout describes the message list as it stood when the dialog opened. The compression
  re-reads that list after the dialog closes, so a turn that lands while the dialog is up is
  summarized but not previewed. Re-fetching inside the modal would only move the same seam.
- `estimateCompressionTokens` and `buildConversationTextForCompression` are deleted rather than kept
  beside the new path; `CompressContextWeights` (two per-message weight columns) and
  `CompressContextSplit` (totals, band, reduction) replace them, and `keepRecentStartIndex` is now the
  single owner of the keep boundary that `selectKeepRecentMessages` also reads.
- A round count that covers every round shows its own message instead of a readout, and an unusable
  count shows nothing until submit — there is no state in which the dialog reports a compression it
  will refuse to perform. A round is still a user message with a *body*: an image-only message is
  not one, so it contributes tokens but never moves the keep boundary.

## Not in scope

- Sending tool results to the summarizer. The summary still sees bodies only; carrying tool payloads
  into a request is a cost and failure-mode decision (chunking, retries, context length) that this
  record deliberately leaves where it is.
- Sizing images from their real pixels. Every image is charged the unknown-size placeholder: reading
  dimensions means reading bytes, and an estimate has no business doing IO.
- Skipping an image because the target model cannot accept image input. That needs the kept
  conversation's model resolved at dialog time, and the bias of charging it anyway points at
  under-promising the saving, which is the direction to be wrong in.
- Counting reasoning tokens, and reviving the image-style savings *bar*: the readout's two numbers and
  its percentage are the whole presentation.
