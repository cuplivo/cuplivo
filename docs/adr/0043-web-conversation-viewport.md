# ADR-0043: Experimental Web Conversation Viewport

Cuplivo will offer an opt-in Web conversation viewport for one-to-one chats on
Android, iOS, macOS, and Windows. Flutter continues to own the application
shell, composer, persistence, generation, tools, and every domain action. The
Web surface owns only DOM presentation, local interaction, and viewport scroll.

## Decision

Dart sends a versioned, renderer-neutral domain snapshot and ordered patches.
Every render session has a conversation id, revision, action epoch, request id,
and private capability token. Dart rejects duplicate or stale actions before
calling existing controllers. Large payloads are UTF-8 chunked; streaming
updates are coalesced per animation frame and patch only affected messages.

Browser assets and reviewed Markdown dependencies are committed locally. The
shell has a deny-by-default CSP, sanitizes generated HTML, denies native
permissions and navigation, and delegates external links to Dart. DOMPurify is
pinned to the reviewed official 3.4.14 bundle, and Markdown uses an explicit
tag and attribute allowlist. Windows loads the versioned cache through a
WebView2 HTTPS virtual-host mapping with folder access set to `deny`; the chat
shell never uses a `file://` origin. Local attachment paths remain only in Dart
registries, while the Web surface receives opaque handles.

The chat shell never executes HTML fences. An `openHtmlPreview` action is
accepted only when Dart can match its bounded source to a current HTML fence in
the targeted message. The source then runs in a separate preview WebView with
no chat-domain bridge or console bridge, denied native permissions, denied
network access, and a sandboxed opaque-origin iframe. A failed rich-content
block is isolated; shell, runtime, resource, and protocol failures use a
Flutter-hosted error surface with retry, content-free diagnostics, and a
conversation-scoped Flutter fallback.

The setting is persisted in SharedPreferences, is device-local, defaults off,
and is excluded from backup/import/export. It is absent on Linux and Flutter
Web. Group chat and MultiAI remain Flutter-rendered. Existing MultiAI cards
force the current conversation to Flutter with a non-cancelable notice;
starting MultiAI from Web remains an explicit confirm/cancel transition. The
same 360-message window and 20-message pagination contract applies to both
renderers.

## Alternatives rejected

- Sharing Flutter's visual-block projection: it would make the Web renderer a
  brittle serialization of widgets instead of an independent presentation.
- CDN assets or a Node build chain: both weaken offline reproducibility and the
  auditable security boundary.
- Replacing Flutter rendering outright: an experimental renderer needs an
  immediate, explicit fallback while behavior and platform runtimes mature.
- Giving JavaScript persistence or tool authority: this duplicates domain
  state and creates an unsafe native capability boundary.

## Consequences

Two renderers must remain behaviorally aligned. Browser rasterization may differ
slightly, but action semantics, domain state, localization, themes, and message
ordering remain Dart-authoritative. Future styling and print work may target
stable DOM component markers without introducing custom scripts in v1.
