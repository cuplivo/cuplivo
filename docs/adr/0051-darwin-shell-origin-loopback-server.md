# ADR-0051: Darwin shell origin — in-process loopback server

ADR-0043 states the Web chat shell never loads from a `file://` origin, but the
Darwin (iOS/macOS) implementation loaded it with `webview_flutter`
`loadFlutterAsset`, which resolves to `WKWebView.loadFileURL` — a `file://`
document origin. On WebKit that origin is opaque, so the shell's ES-module
graph (`app.mjs` importing `protocol.mjs`) is CORS-blocked and the shell never
sends `ready`: the native side reports `shell_ready_timeout` with no JS-side
diagnostics. JavaScript-side retries cannot recover either case — module
evaluation never happens, and the `CuplivoChat` channel wrapper is injected
once per document (`atDocumentStart`), so a missed injection is permanent and a
partial registration can still drop `ready`.

## Decision

On Darwin the shell is loaded from a loopback HTTP origin served by the
in-process `LocalWebChatShellServer`: `assets/web_chat/**` and
`assets/mermaid.min.js` are mapped to `/assets/...` request paths, bound to
`127.0.0.1:0` (ephemeral port), created lazily as a process-level singleton
and never stopped. The server is GET/HEAD only, has a strict path allowlist
(`Uri.path` is percent-encoded, so the path is decoded *before* segment
validation — literal and encoded traversal are both rejected at the boundary,
not by the asset lookup), replies with exact
MIME types (`.mjs` → `text/javascript`; module scripts enforce strict MIME
checking) and `Cache-Control: no-store` so a versioned shell never survives an
app upgrade in the WebKit HTTP cache. The WebView registers `CuplivoChat` and
waits for registration with `await` before `loadRequest`, so `window.CuplivoChat`
exists when the shell's `ready` fires. A failed bind surfaces as
`shell_server_failed` on the existing Flutter-hosted error surface.

ADR-0043's "the chat shell never uses a `file://` origin" now holds on all
supported platforms: Windows (WebView2 HTTPS virtual host), Android
(`appassets.androidplatform.net`), Darwin (loopback HTTP).

## Alternatives rejected

- LoadFlutterAsset / `file://` (status quo): opaque document origin on WebKit
  blocks module fetches; the observed iOS `shell_ready_timeout`.
- JavaScript-side `ready` retry (PR #613): cannot help when the module never
  evaluates, and cannot re-create the per-document channel wrapper.
- Single-file classic-script bundle (drop ES modules): removes the module
  constraint but keeps `file://`; mermaid still loads `../mermaid.min.js`
  outside the read-access directory and the CSP `'self'` guarantee weakens.
- Disk-extracted cache with version markers (Windows pattern): no Darwin
  equivalent of WebView2's virtual-host mapping exists, so the extra temp-dir
  lifecycle adds nothing once HTTP serving is chosen.

## Consequences

- The app now hosts one loopback HTTP server per process on Darwin; bound to
  the IPv4 loopback interface only, serving a fixed allowlist of bundled
  assets — no dynamic content, no directory listing, no LAN exposure.
- Web console messages are forwarded via `setOnConsoleMessage` to
  `debugPrint`, so future Darwin shell failures in the field can be read from
  the device console.
- WKWebView subresource failures remain invisible to `onWebResourceError`
  (main-frame-only); a shell resource failure still surfaces as
  `resource_*` for main-frame errors only.
