# iOS inbound share rides an App Group Share Extension

Cuplivo accepts content shared from other apps through the OS share sheet (issue #710). Android is direct (`ACTION_SEND` on `MainActivity`), but an iOS Share Extension cannot hand images/files to the host app without a shared App Group, and this repo has never used entitlements. We decided to add a `CuplivoShareExtension` target plus App Group `group.com.cup11.cuplivo` on both Runner and the extension, accepting that self-signers must use a provisioning profile carrying the App Group capability (paid Apple ID, or SideStore with a paid account).

## Considered Options

- **Defer iOS (Android-only for v3.3)** — rejected: the feature is expected cross-platform, and the repo already ships an iOS extension target (`GenerationActivityExtension`), so the pattern is not novel.
- **iOS text-only via a custom URL scheme (no App Group)** — rejected: it cannot carry images/files, which are the primary share content, and would make the feature silently inconsistent across platforms.
- **App Group Share Extension (chosen)** — full text/image/file support; the cost is the provisioning capability.

## Consequences

- The Runner target gains its first entitlements file. Distribution is self-signed (README), and free Apple IDs cannot provision an App Group, so the install notes must state the new requirement.
- The extension writes into the App Group inbox; the host consumes it on foreground and imports the files into the normal upload directory. `extensionContext.open` is the intended-but-unreliable auto-foreground API, so a local-notification fallback ("已添加到 Cuplivo · 点按继续") is posted; the host consumes any pending inbox on every activation (`applicationDidBecomeActive`), so no URL or deep link is involved.
- CI stays green (the iOS job builds `--no-codesign`), but the pbxproj / entitlements / extension-target changes need a manual device verification that CI cannot cover.
