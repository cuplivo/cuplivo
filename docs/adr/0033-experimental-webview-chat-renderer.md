# ADR-0033: The experimental chat renderer uses a committed, offline web transcript runtime

Status: accepted for issue #304

Cuplivo provides an opt-in WebView renderer for ordinary one-to-one chat
transcripts on Android, iOS, and macOS. Flutter remains the only owner of chat
data, paging, actions, and persisted state; one reusable WebView receives a
bounded display projection. The native renderer stays the default and the
visible fallback. The web runtime is versioned, works offline, and is committed
as deterministic Flutter assets. Release workflows consume the committed
output; one PR check rebuilds it and rejects drift.

## Runtime contract

The host calls exactly one browser entry point:

```text
window.CuplivoTranscript.postCommand(base64Utf8Json)
```

Decoded commands use this envelope:

```json
{
  "version": 1,
  "id": "host-unique-command-id",
  "sequence": 42,
  "type": "replaceTranscript",
  "epoch": 7,
  "payload": {}
}
```

`version`, `id`, `sequence`, and `type` are required. Every command carries a
non-negative integer `epoch`. `hello` and `replaceTranscript` can establish or
advance the epoch; an older replacement and every non-current patch, theme,
scroll, or resource command fail with `stale_epoch`. Advancing the epoch
releases every object URL from the previous transcript. Base64 is transport
framing, not a security mechanism.

Supported commands are:

| Command | Payload and effect |
|---|---|
| `hello` | Establishes an epoch and negotiates protocol version, capabilities, and explicit exclusions. |
| `replaceTranscript` | Reconciles ordered typed message projections by ID while preserving the visible anchor. |
| `patchMessage` | Changes one existing keyed message without replacing its outer DOM node. |
| `theme` | Updates light/dark colors, fonts, scale, padding, and the proxied assistant background. |
| `renderSettings` | Applies renderer settings such as whether dollar-delimited math is enabled. |
| `scrollToTop` | Moves the document to its current top. |
| `scrollToBottom` | Moves the document to its current bottom. |
| `scrollToMessage` | `{messageId, block?}` scrolls a keyed message into view; block is `start`, `center`, `end`, or `nearest`. |
| `scrollBy` | `{delta}` changes vertical scroll position by a finite CSS-pixel amount. |
| `resourceChunk` | `{resourceId, transferId, index, totalChunks, mimeType, data}` accepts an out-of-order base64 chunk. Completion creates a local blob URL and hydrates `cuplivo-resource://<resourceId>` links/images. Transfers are capped at 4,096 chunks and 32 MiB. |
| `releaseResource` | `{resourceId}` revokes the resource object URL and removes it from hydrated elements. |

The runtime posts stringified JSON events only through
`CuplivoBridge.postMessage`. Each event has `version`, `type`, `epoch`, and
`payload`; command-correlated events also have `commandId`. Every accepted
command ends with `ack`. Rejections produce `error` with a stable `code` and a
diagnostic `message`. Other events are `ready`, `hello`, `resourceReady`,
`viewport` (scroll/resize, anchor, and interaction state), `resourceRequest`,
and typed `action` intents. Events queue until the bridge exists. JavaScript
never executes message operations; Flutter resolves each opaque message or
resource ID against the current epoch before acting.

## Rendering and security boundary

The runtime renders GFM tables and task lists, KaTeX math, and highlighted code.
`mermaid`, `plantuml`/`puml`, `html` aliases, and `svg` fences deliberately stay
escaped source code: Phase 1 does not execute diagram or document content.
Raw Markdown HTML is disabled before parsing and all renderer output is then
sanitized. The committed page has a restrictive CSP, loads no CDN or remote
script/style/font, permits blob/data images only, and permits no network
connections, frames, forms, or plugins. Link navigation becomes a host action.
The runtime does not replace the system selection or copy menu. Message action
buttons use delegated click handling, but selection remains browser-native.
Remote and local images use opaque IDs and a bounded Flutter proxy; the WebView
cannot read paths or make network requests. Attachments are opened by Flutter
and their bytes never enter the WebView.

PDF and browser printing are explicitly outside this phase despite the original
issue proposal. There is no PDF command or fallback. PDF needs a separate host
decision because platform WebViews do not provide one portable print/export
contract.

## Considered options

1. **Build one offline runtime and commit it (chosen).** This keeps every target on identical reviewed bytes, works without Node in release jobs, and makes package-size cost visible. The cost is reviewing generated assets and enforcing drift in CI.
2. **Build in every platform release job (rejected).** It repeats identical work five times and risks platform artifacts being built from different npm installations.
3. **Load renderer libraries from a CDN (rejected).** It makes rendering network-dependent, weakens CSP, and moves executable supply-chain content outside the app release.
4. **Allow raw HTML or execute special fences (rejected).** Sanitization is not a justification for adding active-content surfaces to the main transcript.
5. **Replace the whole transcript on every update (rejected).** It destroys selection, scroll anchors, and DOM identity during streaming; keyed message patches keep the mutation boundary explicit.

## Consequences

- `tool/web_transcript/package-lock.json` is the dependency authority; direct dependencies are exact-pinned and tests use a pinned DOM implementation.
- `assets/web_transcript/manifest.json` hashes every payload file and `manifest.sha256` hashes that manifest. Neither contains timestamps or machine paths.
- The saved renderer preference is distinct from the effective renderer. Group chat, Multi-AI, Windows, Linux, and unhealthy sessions use Native without rewriting the preference.
- Browser behavior is tested in a deterministic DOM environment, but real Android, iOS, and macOS WebViews remain a release-QA boundary.
- PDF, JavaScript-owned business transforms, WebView-per-message rendering, and JavaScript virtual scrolling are intentionally excluded.
