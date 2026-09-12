# ADR-0064: Provider Image Payload Unification — One Markers-Driven Builder, Per-Style Encoding

Provider image handling is spread across six near-duplicate per-message encoders
(Claude, Gemini stream/non-stream, Vertex-Claude, OpenAI Chat Completions,
Responses, LongCat), each re-parsing the same `[image:...]` / Markdown markers
embedded in message content. Claude only reads the last user message's
`userMediaPaths` and emits history markers as literal text; its data-URL branch
even text-izes last-message data URLs (`claude_official.dart:293-294`) despite
the tool-result path handling the same sources correctly. MIME inference exists
in three divergent copies. We unify the parse and the part construction behind
one builder, parameterized by a per-provider style, without touching the input
syntax or persisted format.

## Decision

- **Content markers are the single source of image refs.** Every provider
  parses `content` with the existing `_parseTextAndImages` and encodes the
  resulting refs through one shared converter. PR1 keeps the existing
  `userMediaPaths` / `internalMediaPathsKey` supplemental handling byte-identical
  (Gemini still inline-encodes last-message supplemental paths). Once Claude and
  Vertex consume markers (PR2), those two carriers keep only their non-image
  media roles and their image-MIME entries are ignored — the triple-encode/dedup
  disappears at that point.
- **One converter, per-style descriptor.** `_encodeImageRefParts` (new
  `providers/image_content_builder.dart`) turns one `ImageRef` into provider wire
  parts. PR1 ships the Gemini style (`inline_data`); the Claude `image`-block and
  Vertex-Claude `base64-download` styles are added in PR2. OpenAI-family
  providers resolve their source through `_imageRefSourceUrl` directly (their
  part construction is bound to a second per-URL de-dup and to Responses'
  assistant-image carry), and LongCat keeps its own attachment builder.
  De-duplication stays with the caller, which keeps the existing per-message
  `seenSources` order and supplemental handling byte-identical.
- **Remote mode is per-style, never forced**: `url` (Claude official, OpenAI),
  `base64-download` (Vertex-Claude), `text-degrade` (Gemini official). The
  builder must not download universally or embed universally.
- **Scope is images only.** Non-image media (video/audio/direct-mode docs under
  `internalMediaPathsKey`) stays provider-specific exactly as today
  (`internalMediaPathsKey` remains OpenAI/LongCat-only).
- **Claude/Vertex align up, unconditionally.** They parse every history user
  message like the other providers. This fixes the data-URL text-ization bug via
  the shared builder. Non-image `userMediaPaths` entries are skipped — today they
  were emitted as invalid `image` blocks with video/audio MIME (e.g. a latent
  Anthropic 400).
- **MIME inference converges** on `inferMediaMimeFromSource`:
  `MarkdownMediaSanitizer._guessMimeFromPath` / `_mimeOf` and Vertex's inline
  extension checks delegate to it (image/png fallback preserved). No new
  extensions.
- **Gemini stream/non-stream merge.** The two copies (non-stream `405-482`,
  stream `869-979`) collapse into one contents builder shared by
  `generateContent` and `streamGenerateContent`.
- **Delivery is split.** PR1 = shared `ImageRef` converter (Gemini style) +
  Gemini contents-builder merge (stream/non-stream) + OpenAI `_imageRefSourceUrl`
  reuse + MIME convergence → request bodies stay byte-identical. PR2 = add the
  Claude/Vertex-Claude converter styles (history alignment + data-URL fix +
  non-image skip) as the isolated behavior change.
- **Resizing is out of scope** — filed separately. Manual one-click compression
  already exists at the input bar.

## Considered Options

1. **Full shared message pipeline** (all providers' tool/system/tool-call loops
   in one function): rejected — those loops differ materially (Anthropic
   thinking blocks, Gemini thought signatures, OpenAI reasoning replay);
   unifying them raises regression risk with no dedup gain.
2. **Thin per-ref encoder only** (share the ref→part mapping, keep per-message
   loops): rejected — leaves the six divergent marker-detection/dedup/supplemental
   loops in place, which is the actual defect.
3. **Force base64-download for every remote image**: rejected — breaks Gemini's
   expectations and adds latency/bandwidth to Claude/OpenAI, which accept URLs
   directly.
4. **Gate Claude history images behind a setting** (ADR-0016 precedent):
   rejected — user-message history images are core multimodal behavior, not a
   provider-probe feature; dual behavior would itself be the inconsistency the
   issue targets.
5. **Align down** (all providers send only the last user message): rejected —
   silently drops multimodal history OpenAI/Gemini users already rely on.
6. **Include provider-layer resizing now**: rejected — orthogonal cost/quality
   feature that changes every request's bytes and prompt-cache stability;
   separate issue.

## Consequences

- Claude/Vertex request bodies change: history user images now travel as image
  blocks. Token cost rises; models that reject multi-image must be verified per
  the manual matrix.
- Marker-free conversations stay byte-identical on every provider;
  OpenAI/LongCat/Gemini bodies are byte-identical in PR1 even with markers (the
  builder reproduces their current shape).
- Markdown remote images in history now pass through `_parseTextAndImages`'s HEAD
  validation on Claude/Vertex (OpenAI already does this); `[image:http...]`
  custom markers remain HEAD-free.
- The builder needs per-style unit tests; the existing image tests
  (`chat_api_custom_image_marker_test`, `tool_result_image_roundtrip_test`,
  `chat_api_text_only_image_filter_test`, `openai_images_api_test`,
  `claude_thinking_compat_test`, `gemini_part_id_payload_test`) remain the
  regression net.
- `MarkdownMediaSanitizer` gains a direct import of
  `core/utils/multimodal_input_utils.dart` (a `lib/utils` → `lib/core` reverse
  import; no cycle).
