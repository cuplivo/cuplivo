# ADR-0016: MCP Image Round-Trip: Provider-Side Parsing, Not a Handler Signature Change

The MCP image pipeline (parse → persist → store → UI render) was complete except the return path: `ToolCallHandler` returns `Future<String>`, so every tool result is flattened to plain text and `[image:...]` markers reach the LLM as literal strings the model can never see as images. We fix this at the Provider layer with a minimal closed loop — the handler signature, the DB storage, and the UI rendering stay untouched.

## Decision

- **Reuse the existing shared parser.** `_parseTextAndImages` (`chat_api_service.dart`) already extracts `(cleanText, List<_ImageRef>)` from `[image:...]` markers and Markdown images, with built-in missing-file fallback to text, remote-URL HEAD validation, and fenced-code protection. No new parsing function is added; only per-family part builders are new.
- **Per-family content parts** (all gated by `ProviderConfig.enableToolResultImages`, see below):
  - OpenAI Chat Completions: tool message `content` becomes a parts array with `image_url` (base64 data URL for local files, URL for remote). One builder fix at `_buildOpenAIChatCompletionMessages` covers both history replay and the live tool-call loop.
  - OpenAI Responses API: `function_call_output.output` becomes an array of `input_image`/`input_text` parts (history + live loop).
  - Claude: `tool_result.content` becomes a block array (`image` block with base64 source for local files, `url` source for remote, plus `text` block). Always on — official API documents image blocks in tool results.
  - LongCat Omni: the parallel `_buildLongCatOmniMessages` builder gets the same tool-branch fix (`input_image` parts).
  - Gemini official: untouched — function responses cannot carry images.
- **Text-only models keep remote links.** `_stripImageMarkersFromText` gains a `keepRemoteUrlsAsText` mode: remote `[image:https://...]` refs become bare URL text (no HEAD check) so a search-image tool result can be echoed by the model and rendered by the UI; local-path and data-URL refs stay dropped (device-local junk / base64 blobs).
- **Explicit per-provider control with a conservative default.** New `ProviderConfig.enableToolResultImages` (`bool?`, null = auto): auto = allowlist membership; `true` forces on; `false` forces off. The allowlist is OpenAI official (api.openai.com) + OpenRouter (openrouter.ai) + LongCat. It grows only per real-API verification; unverified OpenAI-compatible vendors default to today's text behavior, and their users can force-enable.

## Considered Options

1. **Change `ToolCallHandler` to return structured content** (rejected): would ripple through the entire type chain — handler, persistence, UI — for a problem the Provider layer already has all the parsing machinery for.
2. **Optimistic default (parts for every vision model)** (rejected): tool-message content arrays with `image_url` parts are not uniformly accepted by OpenAI-compatible vendors; a hard API 400 on every tool call is a full conversation breaker, and the fork's user base skews toward domestic providers that are unverified.
3. **Automatic fallback on API error** (rejected): violates the repo's no-silent-degradation rule (AGENTS 3.6); the explicit toggle is the recovery mechanism.

## Consequences

- DB and UI are untouched: the `[image:...]` marker format is unchanged and remains the single source for both.
- No markers present → request bodies are byte-identical to today (prompt-cache-friendly).
- No-image models are already handled by the outer `_stripImageInputsFromMessages` layer in `sendMessageStream`; the builder-level `canImageInput` gate only matters at the `canImageInput=true` boundary (e.g. Kimi K3: remote refs stay text, local refs become data URLs).
- Request-body log beautifier needs to render the new `function_call_output.output` array and `tool_result.content` block-array shapes.
- **Verification required before relying on any provider**: OpenAI official tool-message `image_url` acceptance, Responses `function_call_output` output arrays, OpenRouter, LongCat payload. Allowlist membership is the audit trail for "verified" providers.
