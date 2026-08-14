# Issue 304 WebView Chat Renderer

This checklist records release-QA work that cannot be proven by Dart widget or DOM-emulator tests. The implementation does not claim these scenarios were run on real Android, iOS, or macOS hosts.

## Happy Path

- Confirm Native is the default under Rendering settings.
- Confirm Android, iOS, and macOS show `WebView (Experimental)` and switch immediately without a confirmation dialog.
- Confirm Windows and Linux do not show the WebView option, including after restoring a backup that contains the WebView preference.
- Render headings, nested lists, tables, task lists, highlighted code, inline math, and display math while offline.
- Select and copy text across several messages with the system WebView selection menu.
- Open HTTPS links, local images, remote images, and local attachments through their Flutter-owned actions.
- Verify assistant background images, light/dark theme, text scale, app font, and code font changes.

## State Transitions

- Switch Native to WebView and back while idle, streaming, and scrolled away from the bottom.
- Switch conversations repeatedly and confirm content from the previous conversation never flashes or arrives late.
- Load older and newer history and confirm the first visible message retains its pixel offset.
- Locate a result outside the loaded window, then use previous/next question and top/bottom navigation.
- Enter group chat or Multi-AI and confirm the effective renderer is Native without changing the saved preference.
- Suspend and resume the app while streaming and while loading an image.

## Failure And Recovery

- Force controller creation, asset loading, handshake, ACK timeout, and main-frame failures.
- Confirm one visible fallback notice appears and Native remains usable.
- Confirm Retry WebView creates a fresh session and Use Native changes the saved preference.
- Confirm a missing, oversized, malformed, redirected, private-host, or unsupported image shows no blank/crashed transcript.
- Confirm repeated failures do not create a rebuild or snackbar loop.

## Security

- Render script tags, event handlers, `javascript:` links, iframes, SVG scripts, CSS imports, malformed JSON, and stale bridge epochs.
- Confirm no script executes, no transcript navigation occurs, and no local path appears in WebView messages.
- Inspect logs and confirm they contain no transcript bodies, API keys, authorization headers, or absolute attachment paths.
- Confirm all Markdown, KaTeX, highlighting, fonts, and sanitizer assets work with network access disabled.

## Performance And Accessibility

- Check a cold 20-message transcript becomes interactive within 3 seconds and a warm renderer switch within 1 second on the release baseline devices.
- Check streaming publish-to-paint p95 remains below 150 ms and scrolling does not regress more than 10 percent from the accepted platform baseline.
- Browse a 5,000-message conversation and confirm memory remains bounded by the loaded message window.
- Confirm only one transcript WebView exists per active chat page.
- Verify keyboard focus, visible focus indicators, Enter/Space activation, reduced-motion behavior, TalkBack on Android, and VoiceOver on iOS/macOS.
