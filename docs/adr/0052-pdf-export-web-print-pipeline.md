# ADR-0052: Conversation PDF Export via Web Print Pipeline

Status: accepted

Issue #293 asks for conversation PDF export. We decided to build it as a
**static branch of the existing Web conversation shell** (ADR-0043): the same
document loads through the same secure origin with a print mode that drives
only the snapshot→DOM render path, then the platform web engine captures the
full document offstage via browser print-to-PDF. We do not use the `printing`
package, the Syncfusion PDF writer, or PNG-slice packing — each rejects the
reproducibility of the web renderer or its print/pagination fidelity.

## Decision

- **Render**: the shell document is loaded with a print-mode flag (no
  interactive protocol, action gate, streaming patches, virtual scrolling,
  or gestures). It renders the FULL conversation — every message in the DOM,
  one render-complete signal, then capture. Virtual range windows must never
  run in print mode.
- **Appearance**: the currently active appearance (snapshot `appearance`
  layers, ADR-0049 style resolution included) is used as-is; a force-light
  option is follow-up, not v1.
- **Entry**: v1 adds a "PDF" row to the existing message export sheet and a
  PDF button to the share/export selection bar (single/batch selection,
  reusing its thinking/tool-card toggles and save flow). Fixed A4 page size
  + 14 mm margins set in the capture settings (CSS `@page` aligned to the
  same values); conversation-batch PDF and user-configurable page size are
  follow-ups.
- **Capture platforms**: implemented = Windows; planned = Android.
  - Windows: `webview_windows` is VENDORED and extended with a `PrintToPdf`
    bridge (its 0.4.0 API has zero print surface; NuGet lifted to
    1.0.2210.55 so `ICoreWebView2_7`/`ICoreWebView2PrintSettings` exist).
    Vendoring reuses the single existing WebView2 controller and its
    `cuplivo-web-chat.invalid` virtual-host secure origin — a separate plugin
    would duplicate both.
  - Android (follow-up): `createPrintDocumentAdapter` writes a temp PDF,
    delivered via the existing bytes-based `saveFile` flow; page size /
    background follow the Android print manager quirks (unknown until a
    spike).
  - On un-implemented platforms the export row stays visible and answers
    with an explicit "Windows only" notice — never silent.
- **Precondition**: the iOS/macOS secure-origin gap. The shell must never run
  on a `file://` origin (ADR-0043), but iOS/macOS currently load via
  `loadFlutterAsset` (`loadFileURL` + `allowingReadAccessTo`) — there is no
  WKWebView virtual-host equivalent, so the compliant fix is a local-loopback
  HTTP server on `127.0.0.1` serving the archived assets. Until that lands,
  macOS/iOS PDF export is unavailable; Linux remains excluded (no WebView).

## Alternatives rejected

- **`printing` package (5.x)**: on native it only generates/prints
  programmatic PDF bytes; its HTML path delegates to `htmltopdfwidgets`, a
  limited HTML→widgets converter (headings/paragraphs/images/lists) — tables,
  code highlighting, KaTeX, Mermaid are lost. It is not a browser pipeline.
- **Syncfusion / `pdf` writer**: would rewrite the Markdown renderer as PDF
  layout objects, recreating the whole renderer with worse fidelity.
- **PNG-slice packing** (existing export-image capture → per-page PDF):
  text loses selectability and the long-file reading experience; cheap, but
  contradicts the issue's archive/print intent.
- **Reusing the interactive shell in place**: renderer unification risks
  pulling live-protocol behavior under print loads; a mode flag keeps the
  branch explicit and testable.

## Consequences

- Any change to the web shell's DOM markers / styles must consider print
  output (same codebase, same fidelity — but also the same fragility).
- The vendored `webview_windows` becomes a repository-owned modified
  dependency; updates must be re-merged consciously.
- Print performance for very long conversations is bounded by full-DOM
  construction and the web engine's print layout — both single-pass, no
  pagination logic in Dart.
