# ADR-0017: Reading Mode Uses Navigator.push on All Platforms (Desktop Deviation)

Reading Mode (阅读模式) — a per-message full-screen view for long assistant answers — is presented via `Navigator.push(MaterialPageRoute(...))` on **all** platforms, including desktop. This deliberately deviates from the desktop navigation convention (AGENTS.md §1.3: 桌面端导航通过 `DesktopHomePage` 的 nav rail / 侧边栏切换页面，不使用 Navigator 路由栈).

## Why

- **Content-length context**: Reading Mode is a transient, content-focused surface for a single message, entered from inside a chat (message More menu) and exited with one back tap. It is not a persistent app section like Settings or Storage — adding it to the nav rail/IndexedStack would pollute the app shell for a per-message action.
- **Dialogs were considered and rejected**: a `showDialog` shell imposes dialog chrome (no full-window text width, constrained height, dismiss semantics) that fights the 720px-cap centered reading column. A pushed route gives the full window and a standard AppBar.
- **Precedent exists**: `DebugPage` is already pushed via `Navigator.push` from `about_pane.dart` (long-press app icon). A full-window route above the `IndexedStack` is an accepted desktop pattern.

## Consequences

- A pushed route covers the window's custom title bar (`WindowTitleBar`); the reader supplies its own chrome (back button + toolbar) in the AppBar, matching the accepted `DebugPage` behavior.
- The reader toolbar (back + copy-all + font −/＋) must be self-contained — no dependence on window-level controls.
- If a future full-screen content surface needs desktop-native chrome (drag regions, window controls), prefer the same route-push pattern over adding it to the sidebar; revisit this ADR only if desktop surfaces multiply to the point of needing a route stack convention.
