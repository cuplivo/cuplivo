# ADR-0049: Declarative Web Conversation Style Library

PR #555 introduced an optional isolated Web conversation viewport for
one-to-one chat. Users may now import named styles for that viewport, but the
style boundary remains data rather than executable Web content.

## Decision

A **Web conversation style** is a `.cuplivo-style.json` document with kind
`cuplivo.web-conversation-style`. Schema v1 exposes three surfaces only:
`userBubble`, `assistantBubble`, and `processCard`. Each surface accepts a
small typed allowlist of colors, dimensions, padding, shadow elevation, and
(for bubbles) maximum width. The app resolves `common` plus the current
`light`/`dark` layer, then places only the validated projection in snapshot
`appearance`. Web chat protocol v4 maps those values to owned CSS variables.

CSS, HTML, JavaScript, selectors, URLs, fonts, images, remote resources, and
viewport background are not part of the contract. The complete imported JSON
object is retained for compatibility and export, but it is never sent to the
WebView. JavaScript validates the allowlist again and clears every style
variable when the default style is selected.

The style library is global. Its single SharedPreferences value,
`web_conversation_style_library_v1`, contains original objects and `activeId`.
It rides normal `settings.json` backup and LAN preference synchronization. The
experimental WebView enable switch remains device-local. A built-in default
entry represents no overrides and is never persisted, deleted, or exported.

## Scope

Styles apply only where the PR #555 one-to-one Web viewport is supported:
Android, iOS, macOS, and Windows. Flutter fallback rendering, group chat,
MultiAI, Linux, and Flutter Web are unchanged. The manager stays accessible
while WebView rendering is disabled and clearly reports that the selection is
not yet effective.

`processCard` styles the outer combined thinking/tool chain. Nested thinking
and tool nodes inherit its presentation instead of drawing duplicate borders.
Assistant styling targets answer surfaces, not the entire assistant message;
user styling targets the complete user bubble.

## Import and compatibility

Imports accept pasted JSON, a local style file or ZIP, and public GitHub
repository/tree archives. GitHub requests use `DioHttpClient` and the global
proxy. ZIP data is scanned in memory, with compressed/uncompressed size and
entry limits; it is never extracted onto the filesystem.

Multi-file imports are selected first, then validated and persisted once. A
single invalid selected item rejects the batch. Duplicate incoming IDs reject
the batch; an existing ID is replaced without changing activation, and import
never activates a style. Unknown fields and future schema versions produce
compatibility warnings. Unknown data is retained but ignored; invalid known
data and documents without an applicable v1 field are rejected.

## Consequences

- Theme palette and semantic colors remain the source of defaults. A Web
  conversation style is not an M3 custom theme and cannot recolor the app.
- Existing font, size, visibility, background-material, Markdown, and behavior
  settings remain independent and are not duplicated by this format.
- Original semantic JSON round-trips, but whitespace and key ordering do not.
- Limits are 64 styles, 64 KiB per style document, 1 MiB total original JSON,
  64 MiB per archive, and 2000 archive entries.

The public schema and an importable example are documented in
`docs/web-conversation-style-format.md` and
`docs/examples/soft-cards.cuplivo-style.json`.
