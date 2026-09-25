# ADR-0001: v4.0 re-baseline on Kelivo v1.3.0 and the platform identity port

**Status:** Accepted (2026-09)
**Deciders:** cuplivo

## Context

Cuplivo 3.x was frozen at v3.2.1 (ADR-0067 on the archived line) and its users were pointed at
upstream Kelivo. Upstream then shipped Kelivo v1.3.0 (2026-09-22, pubspec `1.3.0+79`), a snapshot
that already contains most of what Cuplivo 3.x added (workspace/sandbox, skills, background
generation, scheduled tasks), so a fresh restart on top of it is far cheaper than rebasing the
old fork.

This ADR records the first two commits of the new `cuplivo-4-0` line:

1. **the platform identity port** (`com.cup11.cuplivo`, the identity the fork line had been using), and
2. **the developer rename** (`com.cuplivo.cuplivo`, developer `cuplivo`).

The branding boundary inherited from the archived line (**ADR-0003**, **ADR-0029** and its
`CONTEXT.md` "Branding & Naming Boundary" glossary) is the standard this port follows: rename every
user-visible and outbound identity surface, and keep every name that is part of a protocol,
persisted data, or external infrastructure we do not control.

## Decisions

### Identity

| Item | Decision |
| --- | --- |
| Commit 1 identity | `com.cup11.cuplivo` (applicationId/namespace, bundle ids, app groups, JNI package path) — taken from the archived fork line |
| Commit 2 identity | `com.cuplivo.cuplivo`, developer `cuplivo` (replaces the `cup11` handle in ids, attribution and copyright fields) |
| Developer attribution | Windows version-info `CompanyName` `com.cuplivo` + `LegalCopyright` holder `cuplivo`, macOS `PRODUCT_COPYRIGHT` holder `cuplivo` |
| Dart package | `Cuplivo` (`package:Cuplivo/...`) |
| Version | restarts at `4.0.0+1` (Cuplivo lineage: 3.2.1 → 4.0) |
| App scheme (OS-registered) | app's own deep links use `cuplivo`; MCP OAuth callback follows the app id (`com.cup11.cuplivo` → `com.cuplivo.cuplivo`) |
| Repository / update source | `github.com/cuplivo/cuplivo` (update check reads that repo's GitHub Releases) |

Because the applicationId changes, a Cuplivo 4.0 install does **not** overwrite a Kelivo or
Cuplivo 3.x install: the app installs side by side and starts with fresh data. No migration code is
written for this — users keep the old app's data and can restore from a backup if they want it.

### Schemes are split by role

One `kelivo://` string covered two different jobs upstream:

- **OS-registered deep links** (share activation, `oauth-return`, conversation links, MCP OAuth
  callback) are entry points with no persisted payload, so they follow the app identity
  (`cuplivo`, `com.cup11.cuplivo`). This also avoids competing with an installed Kelivo for
  `kelivo://` routing — side-by-side installs are expected after this change.
- **Content and protocol links** are kept: `kelivo://workspace|chat|session|skills|tmp|mounts`
  (emitted to models, stored in messages, parsed by the file-link resolver), `kelivo-file://`
  attachment URIs, the guest-shell OSC marker `KelivoOpenURL`, and `kelivo_*` / `@kelivo/*` MCP tool
  ids. Renaming these would break imported conversations and recorded tool calls for no
  user-visible gain.

### Superseded decisions from the archived line

- **Sponsor**: ADR-0003 removed the sponsor page; ADR-0029 later kept `afdian.com/a/kelivo` and
  `kelivo.psycheas.top` as external infrastructure. **Kept unchanged** in v4.
- **Update check**: ADR-0003 disabled it; the archived line had already repointed it at its own
  releases. v4 reads `https://api.github.com/repos/cuplivo/cuplivo/releases/latest` (with per-ABI
  APK selection); it is never pointed at the upstream `update.json`, which would prompt users to
  install a different app.
- **Discord**: ADR-0003 removed the upstream Discord row because Cuplivo had no community of its
  own. v4 ships **Cuplivo's own** invite (`discord.gg/kaTf8CXG4`) alongside the Cuplivo QQ group
  (`qm.qq.com/q/9Rnnf7XyNO`); the upstream QQ groups are dropped.

### Built-in removals (fork boundary)

- The `KelivoIN` provider is no longer seeded or special-cased; a persisted config of that name
  stays usable as an ordinary dynamic provider.
- The built-in `kelivo` search service (`search.psycheas.top` with an embedded token) and its About
  Easter egg are removed: a fork must not silently route user queries to the upstream author's
  server. Its l10n keys are deleted with it.

### Assets and docs

- App icon and platform icons come from the fork line's artwork (the fox mark); the desktop header
  and Linux tray use that mark, while `assets/icons/kelivo.png` stays only as the `kelivo`
  provider-icon regex target.
- `README.md` / `README_ZH_CN.md` keep the upstream structure and feature list (this line *is*
  upstream + identity) with Cuplivo naming, Cuplivo community links, upstream attribution in
  Acknowledgements, and an explicit "community fork" note.

## Consequences

- Kelivo names remain, by design, on these surfaces: `kelivo_*` MCP tool ids, `kelivo://` and
  `kelivo-file://` schemes, `KelivoOpenURL`, `kelivo_backups` / `kelivo.db` and other persisted
  names, `kelivo.psycheas.top` / `search.psycheas.top` / `afdian.com/a/kelivo` URLs,
  `KelivoImageSettingsMapper` and "Kelivo backup" interop terms, internal code identifiers
  (`KelivoFileUri`, `KelivoApplication`, `KelivoISH*`, `kelivo_fetch/`, isolate labels), and
  upstream references in README/CHANGELOG.
- The `kelivo-file://` whitelist accepts both lineages (`com.psyche.kelivo`, `psyche.kelivo`,
  `com.cup11.cuplivo`, then `com.cuplivo.cuplivo`) so backups and legacy absolute paths from either
  line still resolve. Its Windows matcher likewise accepts the `com.psyche` / `com.cup11` /
  `com.cuplivo` `AppData` vendor prefixes produced by each lineage's version-info `CompanyName`.
- No new ADR is needed to rename the remaining protocol surfaces later; if that ever happens, the
  cost is documented in `CONTEXT.md`.

## Not in scope

- Porting the `CuplivoSymbolFallback` font, the `website/` workspace, CHANGELOG or a v4
  re-baseline announcement.
- Rebranding the GitHub issue templates / FUNDING (still upstream-worded, as on the archived line).
