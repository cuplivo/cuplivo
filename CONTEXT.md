# Cuplivo Context

Domain language for this repository. Terms here are decision-bearing: an ADR or a code comment that
contradicts one of them is a bug, not a preference.

## Project lineage (项目血脉)

- **Kelivo**: the upstream project (`Chevey339/kelivo`) this app is a fork of. Versions are its
  own (`v1.3.0`); the name legitimately appears in attribution, interop terms and external URLs.
- **Cuplivo 3.x**: the archived fork line (forked from Kelivo v1.1.17, terminal release v3.2.1),
  source of the identity values
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
  and preview temp files), and the release/build identity: artifacts
  `Cuplivo_<platform>_<version>_<arch>`, the Windows installer's own AppId
  `B924949D-FD7C-4688-B812-4ED64BFAACDC` (never upstream Kelivo's, or the two installers would
  upgrade and uninstall each other), publisher `cuplivo`, `cuplivo.exe`, DEB/RPM packages named
  `cuplivo`.
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

## Release & upstream policy (发版与上游策略) — ADR-0004

- **Follow upstream (随上游)**: a new version re-bases the code base on the latest Kelivo stable and
  re-does Cuplivo's own features on that baseline (cherry-pick) instead of diverging permanently.
  4.0 is the first line built this way; 3.x ended because hand-syncing every upstream change became
  unmaintainable.
- **Coexistence, not migration (并存而非迁移)**: the application id differs from every other
  lineage, so a 4.x install never overwrites Kelivo or Cuplivo 3.x, and data is never migrated
  automatically.
- **Migration path from 3.x (从 3.x 迁移)**: 3.x's 「数据迁移 → 导出 Kelivo 兼容备份」
  (`backupMigrateExportLabel`) produces the full backup this line can restore; the plain backup
  export is not that file.
- **Removed 3.x features (未随行的 3.x 功能)**: group chat, the multi-AI side-by-side comparison,
  the delete-recovery / recycle bin and subagent delegation were not re-implemented on the new
  baseline; `CHANGELOG*.md` records them per release.

## Community channels (社区入口)

- **Cuplivo QQ group**: `1101061750` — `https://qm.qq.com/q/9Rnnf7XyNO` (the only QQ entry).
- **Cuplivo Discord**: `https://discord.gg/kaTf8CXG4`.
- Upstream Kelivo's community channels are not listed in the app.

## Image Compression (图片压缩) — ADR-0002

- **Compression mode (压缩模式)**: one mutually exclusive stance for how attached images are handled,
  chosen in settings.
  - **auto (自动)**: every attached image is re-encoded at attach time with the configured preset, through
    the same 工作图 decode the editor uses. A source over the 工作预算 is skipped like any other skip, so the
    attachment keeps its pristine bytes instead of risking the process.
  - **manual (手动)**: attachments are kept as pristine originals and the compress editor is the only
    compression surface. This is the default.
  - **off (关闭)**: attachments stay pristine and no compression UI is offered at all.
- **Original (原图)**: an attachment whose bytes are exactly what the picker handed over, before any
  re-encode. It is also the third choice in the editor's format control, meaning "keep this image as it
  is" — the escape hatch that makes per-image skipping explicit instead of inferred.
- **Format (格式)**: the output encoding the user picks — JPEG (lossy, has 质量) or PNG (lossless, no
  质量). WebP is never produced: some providers reject it.
- **Working image (工作图)**: the pixels the editor actually holds — the source decoded once at the
  resolution the artifact will have, so peak memory follows the chosen output rather than the file.
  It is bounded by the working budget (14 MP mobile / 20 MP desktop), and its long edge is what the
  long-edge slider can reach. See ADR-0005.
- **Retired working image (已退休工作图)**: a 工作图 a re-decode replaced while the preview may still be
  drawing it. It is released only after the frame that publishes its replacement has painted, because a
  painter captures the image it draws and an animation repaints it without a rebuild — releasing at the
  swap drew a disposed image once per frame. See ADR-0005 decision 11.
- **Reference image (参考图)**: the source decoded once at its reachable long edge, kept for the session
  as the comparison's original side. It exists because the left half used to be drawn from the 工作图,
  which is decoded at the *target*: lowering the resolution then blurred 原图 along with the result
  until the two halves differed only by the encoding, hiding the loss the slider was causing. It is
  display-only — nothing is ever encoded from its pixels — and it is never decoded at all while the
  target is the reachable edge, because there the 工作图 already holds those exact pixels. See ADR-0005
  decision 13.
- **Working budget (工作预算)**: the ceiling on a working image, in pixels, and on a single decode, in
  bytes. The byte ceiling is judged twice, because the risks differ: the raster a decode would allocate
  against the whole budget, and the source file held twice against half of it. A file-inclusive
  judgement used to refuse sources whose decode is cheap — a 200 MP JPEG needs 280 MB of raster and was
  refused for its 30 MB file. When a source cannot be decoded inside the budget, the editor refuses with
  an explanation and no apply action rather than risking a process abort — an out-of-memory kill inside
  a decode is not catchable from Dart. The refusal is a state, not a dead end: the panel keeps the
  source's dimensions and its long-edge control, because a smaller 工作图 is what makes a borderline
  source fit.
- **Artifact (产物)**: the exact byte sequence the current parameters produce, encoded from the working
  image. The size row shows its length, the compressed side of the 分屏对比 draws it, and the apply
  writes those same bytes, so the three can never disagree. It is dropped the moment a parameter
  changes, and only ever written while its parameters still equal the selected ones.
- **Long edge (长边)**: the target size of the image's longest side. It only ever shrinks, and its
  reachable range ends at the working image's long edge, so the slider cannot promise a resolution the
  pipeline will not produce. When the source had to be reduced to fit the budget, the panel says so.
- **Quality (质量)**: 30-100 lossy strength, meaningful for JPEG only — the editor's slider
  floor is 30, and the stored value is clamped to the same range.
- **Savings (节省)**: (original bytes − artifact bytes) / original bytes, shown before the user
  commits. The row reads as two sides — resolution above size on each side — with the change above an
  arrow between them. A PNG of a photo can legitimately grow, and the row says so before the apply by
  showing that growth (a `+N%` warning tone) instead of hiding it.
- **Split compare (分屏对比)**: the editor body's 1:1 comparison — the original on the left of a
  draggable divider, the artifact on the right, over the region on screen. The right half is the
  artifact's own pixels, so 1:1 means one artifact pixel per logical pixel; the left half draws the same
  region from the 参考图, so 原图 is never a re-decode at the target. The image is letterboxed inside the
  preview area at its own aspect ratio, never stretched or cropped to fill it; the default framing fits
  the viewport's width and never magnifies, so a tall screenshot stays legible instead of shrinking to a
  strip, and every framing keeps that aspect ratio and is bounded by it — a zoom cannot leave the window
  narrower than the preview area. Changing a parameter drops the shown artifact immediately, so a stale
  encode is never presented as the current one.
- **Apply to all (应用到全部)**: broadcasts the editor's current parameters to every attached image.
  Only the image the editor was opened for can reuse the editor's artifact; the others run the same
  budgeted pipeline themselves.
- **Processing gate (处理门)**: what the composer hands the editor when the chip it was opened from is
  still running its attach-time pass. The dialog opens on the click and prepares behind that pass,
  because decoding beside it is the doubling the single-pass rule forbids. Until a 工作图 exists there is
  no artifact to write, so the apply actions stay disabled while only closing is offered.
- **Remembered parameters (记住的参数)**: the last parameters the user confirmed in the editor — 原图
  included — which seed the next editor session. A long edge remembered from a larger image is
  normalised to the image being edited once its size is known, so the panel's readout always equals
  what will be applied.
- **Draft-owned copy (草稿自有副本)**: a stored copy the draft itself created. It is released when the
  chip is dropped from the composer, but never once the attachment has been submitted: a persisted
  message may reference it.
- **Compressed file naming (压缩产物命名)**: a compressed artifact is named `.jpeg` or `.png`, never
  `.jpg`: some providers accept only the `jpeg` spelling. A pristine copy keeps the name it was
  picked under, except that an extensionless pick gets the extension its own bytes imply, because
  MIME inference would otherwise declare it `image/png` whatever it holds. `.jpg` and `.jpeg` count
  as one name family when identical bytes are deduplicated.

### Relationships

- Exactly one 压缩模式 is active. 原图 attachments exist in 手动 and 关闭; re-encoded ones exist in 自动 or
  after an explicit editor apply.
- 质量 applies to JPEG only, so PNG hides the control.
- 自动 and 手动 share one 工作图 decode and one 工作预算; they differ in who decides the parameters and in
  what happens to a source that cannot be worked: 自动 skips it and keeps the pristine copy, 手动 offers no
  apply action and says why.
- The editor is offered only where it can act: an attachment whose bytes cannot be decoded shows no
  apply action, a source that cannot be decoded inside the 工作预算 shows an explanation and no apply
  action, and a remote or `data:` attachment never opens the editor at all. A chip whose pass is still
  running is waited out through the 处理门 rather than refused: the click is answered at once.
- The 分屏对比, the size row and the artifact written to disk are one value; a difference between them
  is a bug, not a preview artifact. The shown artifact belongs to the parameters currently selected.
- The working image and the artifact are at the same resolution by construction, so a re-encode can
  never exceed the working image's long edge, and 1:1 is always one artifact pixel per logical pixel.
- The 参考图 sits at the reachable long edge and the 工作图 at the target, so the original side of the
  分屏对比 stays put while the slider moves: the note that says the source was loaded at a percentage to
  stay within memory names that same reachable edge, not the target the user chose.
- Manual compression is one-way: the editor re-encodes from the image's current stored bytes, so
  re-compressing a compressed image loses another generation, and the pristine 原图 is not recoverable
  once a compression has been applied. An applied artifact may differ byte-for-byte from what an older
  build produced for the same parameters, because the resampling now happens in the decode.
- Short edge case that motivates the manual default: a long screenshot whose long edge is far larger
  than any preset cap would be reduced to illegibility by 自动, so 手动 leaves that decision to the user.
  The same screenshots are why the editor decodes at the artifact's size instead of the source's.
