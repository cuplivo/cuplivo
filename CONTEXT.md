# Cuplivo Context

Domain language for this repository. Terms here are decision-bearing: an ADR or a code comment that
contradicts one of them is a bug, not a preference.

## Project lineage (项目血脉)

- **Kelivo**: the upstream project (`Chevey339/kelivo`) this app is a fork of. Versions are its
  own (`v1.3.0`); the name legitimately appears in attribution, interop terms and external URLs.
- **Cuplivo 3.x**: the archived fork line (terminal release v3.2.1), source of the identity values
  and boundary decisions this line inherits.
- **Cuplivo 4.0 / `cuplivo-4-0`**: this line — a re-baseline on Kelivo v1.3.0 with the Cuplivo
  identity, version `4.0.0+`.
- **Legacy K/C data**: data produced by either lineage (Kelivo installs, Cuplivo 3.x backups).
  Both must keep resolving on import; see Identity below.

## Branding & Naming Boundary (品牌与命名边界) — ADR-0001, ADR-0029

- **Renamed surfaces (已更名面)**: everything a user or a third party can see or receive —
  application id / bundle ids / app groups, app and window titles, notification strings and channel
  names, notification/thread ids, about-page text, share-extension text, HTTP `User-Agent`,
  OpenRouter `X-OpenRouter-Title` + referer, MCP client name, OS-registered URL schemes, and
  downloaded/temporary file prefixes (`cuplivo_tts_`, `cuplivo-table-`, `cuplivo-mermaid-`, export
  and preview temp files).
- **Legacy Kelivo surfaces (旧名保留面)**: names kept on purpose because they are protocol,
  persistence, or external-infrastructure identity, and renaming them breaks data or model-facing
  behavior:
  - `kelivo_*` MCP tool names and `@kelivo/*` server ids — persisted in assistant config and
    recorded in tool events and conversation history.
  - `kelivo://` content links (`workspace`, `chat`, `session`, `skills`, `tmp`, `mounts`,
    `terminal`) — emitted to models, stored in messages, parsed by the file-link resolver.
  - `kelivo-file://` attachment URIs — the wire form stored in messages and backups.
  - `KelivoOpenURL` — the OSC 1337 marker the guest shell emits and the terminal strips.
  - `kelivo_backups`, `kelivo.db`, `kelivo.restore-*`, `.kelivo_restore`, `kelivo-schedule`,
    `kelivo_background` and other persisted keys/format ids.
  - `kelivo.psycheas.top`, `search.psycheas.top`, `afdian.com/a/kelivo`, `kelivo-helper` — external
    infrastructure Cuplivo does not control.
  - `KelivoImageSettingsMapper` and "Kelivo backup" interop terms — they describe the upstream
    project, which still exists.
  - Internal identifiers: `KelivoFileUri`, `KelivoApplication`, `KelivoISH*`,
    `kelivo_fetch/`, isolate/queue labels, guest-side script and path names
    (`kelivo-open`, `.kelivo-ish-build`, `/run/kelivo/...`).
- **Rule of thumb**: if a third party or a stored payload can observe the string, rename it; if it
  is a key into stored data or a name on the wire between two processes, keep it.

## Identity (身份)

- **App scheme vs content scheme**: OS-registered deep links use `cuplivo` (MCP OAuth callback uses
  the current application id); the `kelivo://` namespace is content, never registered with the OS.
- **Side-by-side installs**: the applicationId differs from both Kelivo and Cuplivo 3.x, so
  installs coexist and never overwrite each other. Data migration is therefore *not* implemented;
  restoring a backup is the supported path between them.
- **Legacy bundle ids**: the `kelivo-file://` whitelist accepts `com.psyche.kelivo`,
  `psyche.kelivo`, `com.cup11.cuplivo` and `com.cuplivo.cuplivo`, and the Windows `AppData` vendor
  prefixes `com.psyche` / `com.cup11` / `com.cuplivo`, so backups and absolute paths recorded by
  either lineage keep resolving.

## Community channels (社区入口)

- **Cuplivo QQ group**: `1101061750` — `https://qm.qq.com/q/9Rnnf7XyNO` (the only QQ entry).
- **Cuplivo Discord**: `https://discord.gg/kaTf8CXG4`.
- Upstream Kelivo's community channels are not listed in the app.

## Image Compression (图片压缩) — ADR-0002

- **Compression mode (压缩模式)**: one mutually exclusive stance for how attached images are handled,
  chosen in settings.
  - **auto (自动)**: every attached image is re-encoded at attach time with the configured preset.
  - **manual (手动)**: attachments are kept as pristine originals and the compress editor is the only
    compression surface. This is the default.
  - **off (关闭)**: attachments stay pristine and no compression UI is offered at all.
- **Original (原图)**: an attachment whose bytes are exactly what the picker handed over, before any
  re-encode. It is also the third choice in the editor's format control, meaning "keep this image as it
  is" — the escape hatch that makes per-image skipping explicit instead of inferred.
- **Format (格式)**: the output encoding the user picks — JPEG (lossy, has 质量) or PNG (lossless, no
  质量). WebP is never produced: some providers reject it.
- **Long edge (长边)**: the target size of the image's longest side. It only ever shrinks.
- **Quality (质量)**: 0-100 lossy strength, meaningful for JPEG only.
- **Savings (节省)**: (original bytes − result bytes) / original bytes, shown as an estimate before the
  user commits. A PNG of a photo can legitimately grow, and the estimate is what tells the user so
  before they apply it.
- **Split compare (分屏对比)**: the editor body's 1:1 comparison — the original on the left of a
  draggable divider, the current parameters' result on the right, over the region on screen.
- **Apply to all (应用到全部)**: broadcasts the editor's current parameters to every attached image.
- **Compressed file naming (压缩产物命名)**: a compressed artifact is named `.jpeg` or `.png`, never
  `.jpg`: some providers accept only the `jpeg` spelling.

### Relationships

- Exactly one 压缩模式 is active. 原图 attachments exist in 手动 and 关闭; re-encoded ones exist in 自动 or
  after an explicit editor apply.
- 质量 applies to JPEG only, so PNG hides the control.
- The 分屏对比 and the artifact written to disk must come from the same parameter pipeline; a visible
  difference between them is a bug, not a preview artifact.
- Manual compression is one-way: the editor re-encodes from the image's current stored bytes, so
  re-compressing a compressed image loses another generation, and the pristine 原图 is not recoverable
  once a compression has been applied.
- Short edge case that motivates the manual default: a long screenshot whose long edge is far larger
  than any preset cap would be reduced to illegibility by 自动, so 手动 leaves that decision to the user.
