# Cuplivo Domain Glossary

## Title Preset System
- **Hash Fingerprint matching**: `detect()` uses `trim()` only (conservative), exact character match after stripping leading/trailing whitespace.
- **PromptPreset data class**: `id`, `label`, `prompt` fields only. No `recommendedThinking` — presets are style-only, Thinking is independently controlled.
- **Dirty state**: real-time `detect()` on every text change; dropdown label switches to "自定义" when content no longer matches any preset.

## UI Interaction Model
- **Desktop** uses `DesktopSelectDropdown<String>` with `__custom__` sentinel for unmatched prompts.
- **Mobile** opens a `showModalBottomSheet` with `IosCardPress` options.
- Both are wrapped in `ListenableBuilder(controller)` so the dropdown label updates immediately on preset click or text edit, without auto-saving.
- "重置全部" button: resets both prompt text (`resetTitlePrompt()`) and Thinking switch (`resetTitleGenerationThinkingEnabled()`). No separate [↺] on the Thinking row.

## Prompt Preset Screen Layout

```
┌──────────────────────────────────┐
│ _TitleThinkingSwitchRow          │
│                                  │
│ 提示词              [▼ 标准✓]   │
│                                  │
│ ┌──────────────────────────────┐│
│ │ 可编辑文本框                  ││
│ └──────────────────────────────┘│
│ 可用变量: {content} {locale}    │
│ 更改预设后需点击「保存」方可生效 │
│                                  │
│ [重置全部]              [保存]   │
└──────────────────────────────────┘
```

## Title Generation Prompts

- **emojiTitlePrompt**: A preset variant of the title generation system prompt that allows ONE relevant emoji at the beginning of the title (followed by a space). No other punctuation or special characters are permitted elsewhere. The character limit (≤10) excludes the emoji.

## SVG Rendering in Chat

- **SVG code block** (` ```svg `): rendered via `SvgCodeBlock` widget (tab UI: "SVG" image tab + "Code" tab, reuses `mermaidImageTab`/`mermaidCodeTab` ARB keys). Uses `SvgPicture.string()` to render inline SVG XML. No streaming support (streaming SVG fragments are almost always invalid XML).
- **Markdown image SVG**: `imageBuilder` detects `.svg` extension in URL and `data:image/svg+xml;base64,...` pattern, routes to `SvgPicture.network()` or `SvgPicture.string()` respectively.
- **Known limitation**: URLs without `.svg` extension (e.g. shields.io badges like `https://img.shields.io/badge/release-1.0.0-blue`) are not detected as SVG. The user must ensure LLM output includes `.svg` suffix, or append it manually. Deliberate trade-off: avoids an extra failing HTTP request for every extensionless URL.

## Input Draft Persistence

- **InputDraftPersistence**: `lib/features/home/services/input_draft_persistence.dart`. Owns debounced (800ms) writes + lifecycle immediate save of chat input draft via `SharedPreferences`.
- **Scope**: Single global draft (`chat_draft_v1` key). Not per-conversation — the input is shared across conversations.
- **Persistence**: JSON blob with `{text, images[], documents[{path,fileName,mime}]}`.
- **Restore**: On cold start only, in `_ChatInputBarState._restoreDraft()`. Sets `TextEditingController.text` + media lists.
- **Clear**: On send success or when input is fully empty. Debounce skips empty content.

## App Update Notice (新版本提示)

- **Update entry (新版本入口)**: A compact single row (icon + `发现新版本：{version}` + dismiss X + chevron) that replaces the old full-changelog banner at the top of the conversation list. Placement: mobile drawer bottom bar, above the user avatar/nickname row; desktop sidebar bottom (below the conversation list — desktop hides the user row, `showBottomBar: false`). Exactly one entry per configuration: the right topics panel (`desktopTopicsOnly`, topics-on-right mode) never renders the entry, so it stays at the main left sidebar bottom. Visible only when `UpdateProvider.available != null`, `settings.showAppUpdates` is on, `!UpdateProvider.dismissed`, and a platform download URL exists (`bestDownloadUrl()`).
- **Changelog dialog (更新日志弹层)**: Shared dual-shell component (`UpdateChangelogDialog.show` desktop centered Dialog / `showSheet` mobile bottom sheet — same "same content, different shell" pattern as `ImageCompressionDialog`). Header row: close X + version + [下载] button; below: scrollable release notes markdown. Download failure falls back to copying the URL + snackbar (reuses `sideDrawerLinkCopied`).
- **Session-scoped dismiss (会话级关闭)**: `UpdateProvider.dismiss()` sets an in-memory flag that hides the entry until the next app launch. NOT persisted — the provider is recreated on startup, so a still-pending update reappears after restart. The dismiss never blocks the entry after restart.

## Incremental Backup (Experimental)

- **Data scope**: Chat data (conversations + messages + toolEvents + geminiThoughtSigs). Optionally includes files (upload/, images/, avatars/, fonts/) when `includeFiles=true`, filtered by mtime >= since.
- **Filtering unit**: Message-level (`message.timestamp >= since`). Conversations created before `since` are still included if they have recent messages; only those messages are exported. Uses `updatedAt` as a fast pre-filter to skip inactive conversations. See `docs/adr/0002-conversation-level-incremental-filtering.md`.
- **File naming**: `cuplivo_incr_<export_ts_YYYYMMDD-HHmmss-ffffff>_<since_ts_YYYYMMDD-HHmmss>.zip`. The `cuplivo_incr_` prefix is the single identification mechanism for the restore path.
- **Restore behavior**: `cuplivo_incr_` prefix detected → skip the "Overwrite/Merge" dialog entirely → force `RestoreMode.merge` at both UI and DataSync layers.
- **Date source**: `BackupReminderProvider.lastBackupTime` for the [↻] shortcut. If null, fallback to 30 days ago. User can always override via `showDatePicker()`.
- **`includeSettings`**: Default `true`. Not yet persisted (planned for a future PR).
- **`includeFiles`**: Default follows the config's `includeFiles` toggle. Files are filtered by `lastModifiedSync() >= since`. Not persisted.
- **Architecture**: Incremental backup is NOT a mode toggle on full backup — it's a separate independent action. `BackupProvider.incrementalBackup(IncrementalBackupConfig)` and `S3BackupProvider.incrementalBackup(IncrementalBackupConfig)` are new methods that don't modify existing `backup()`.
- **UI placement**: Desktop & Mobile. Each target (WebDAV, S3, Local) gets its own incremental section within its existing card, with date picker + [↻] shortcut + settings toggle + includeFiles toggle + separate action button.
- **User-visible behaviors**:
  - Export filename always starts with `cuplivo_incr_`
  - Export includes settings if `includeSettings=true`, includes files if `includeFiles=true` (filtered by mtime)
  - Import automatically skips mode selection for `cuplivo_incr_` files
  - Empty export (0 conversations matched) shows a confirmation warning before producing the file

## Multi-AI Comparison Mode (Side-by-side)

- **Trigger**: 
  - **User messages**: No entry point.
  - **Assistant messages**: MessageMoreSheet "Multi AI" action → "让其他 AI 也回答". Uses pre-selected models from model selector; if none pre-selected, opens multi-model selector via `showMultiModelSelector()`. Comparison starts **immediately** via `startRoundFromHistory()`.
  - **Model selector**: Dual-mode (single/multi) in `_ModelSelectSheet`. Select ≥2 models → 确定 → enters multi-AI mode via `multiAIEngine.enter()`.
- **Data model**: `ChatMessage.subgroupId` (nullable TEXT). Within the same `groupId`, multiple `subgroupId`s represent different model responses as **cards**. `subgroupId = null` messages follow existing collapse/version behavior.
- **Card rendering**: When a `groupId` has any message with `subgroupId != null`, render cards (PageView) instead of a single collapsed message. Each card shows one subgroup's selected version using full `ChatMessageWidget`.
- **Resolve (adopt)**: ALL threads across ALL rounds get `subgroupId = NULL`, reassigned continuous versions, adopt version stored in `versionSelections[groupId]`. Exits card mode. Exits multi-AI engine mode.
- **Drop**: A single thread's messages get `subgroupId = NULL` (keeping version), exits that card but stays in version pool. Model pool shrinks by 1 via `removeThread()`. Physical DB rows unchanged.
- **Streaming**: N concurrent streams, each writing to their own messageId. Existing `StreamingContentNotifier` per-message architecture handles this.
- **Engine state** (MultiAIEngine, in-memory only): `_models`, `_threadIds`, `_isActive`. NOT persisted — recovery happens from `ChatMessage.subgroupId` + `providerId`/`modelId` in conversation history.
- **Persistence recovery**: On conversation switch via `switchConversationAnimated`, scan `_messages` for `subgroupActiveGroupIds`, extract `{providerId, modelId}` from latest round's subgroup messages, restore model selector badge via `multiAIEngine.recoverFromMessages()`.
- **Mode lifecycle**:
  - Enter: Select ≥2 models → 确定. Or: assistant message "更多" + trigger.
  - Lock: Once active, model selector button is locked → shows pill badge with ✕ and model count. Click shows snackbar "多 AI 模式已激活".
  - Exit: Click ✕ on badge, resolve (adopt), deselect to 1 model, switch conversation.
  - Drop: Reduces model pool synchronously via `removeThread()`.
- **Model selector interaction**:
  - Normal: single-select (existing behavior).
  - Multi-select mode: checkboxes in `_ModelSelectSheet` + 确定 button. Long-press still opens ProvidersPage.
  - When N≥2 selected → enter multi-AI mode.
  - When locked: click → snackbar toast.
- **Send behavior**: When multi-AI mode active, typing send triggers `startRound` for ALL models (N parallel threads).
- **startRoundFromHistory**: Called when user clicks "让其他 AI 也回答". Finds preceding user message, assigns it `roundGroupId` (persisted via `chatService.updateMessage` with `groupId`), creates N assistant placeholders with `subgroupId`s, starts N streams using conversation history as API context. No new user message created.
- **UI**: `MultiAICardGroup` with PageView (horizontal swipe). Card has Resolve ✓ / Drop ✕ per card. `ChatInputBar` retained with badge `{count} 个模型` and ✕ button.

## Image Attachment Compression

- **Trigger**: Per-image via clicking file size label below thumbnail; batch via dialog's "全部压缩" button. All ingress paths (gallery, camera, file picker, drag-and-drop, clipboard paste) treated identically.
- **Dialog**: `ImageCompressionDialog` in `lib/shared/dialogs/image_compression_dialog.dart`. Follows incremental backup pattern: `show()` for desktop (centered Dialog), `showSheet()` for mobile (bottom sheet). Same content, different shell.
- **Dialog controls**: Quality slider (30-100), max-dimension slider (320 to original long-edge, step 64px, shortcuts: 原始 / 1/2 / 1/4), format option (仅在有 alpha 通道的 PNG 时显示: "保留透明度 PNG" / "转为 JPEG 白色背景").
- **Format detection**: Done in `_openCompressionDialog` via `img.decodeImage()` (pure Dart, no GPU). Detects real pixel transparency (`decoded.hasAlpha && any(px.a < maxChannelValue)`). Result passed to dialog as `hasRealAlpha`. Eliminates separate file header parsing.
- **Compression core**: `ImageCompressor.compressIfNeeded()` in `lib/utils/image_compressor.dart` (credit: Ankairis, PR #705). Decode/encode in background isolate via `compute()`. Parameters: `quality` (1-100), `maxDimension` (resize longest edge, maintain aspect ratio), `keepPng` (override format detection). Defensive: on exception or result≥original, return original path unchanged.
- **File strategy**: Compressed result written to same dir, same basename, new extension (e.g. `photo.png` → `photo.jpg`). Original file deleted. `_images` path updated accordingly.
- **UI**: File size shown as gradient overlay at bottom of each 64×64 thumbnail, with `Lucide.ImageDown` icon. Tappable → opens dialog. `_imageSizes` cache maintained alongside `_images` to avoid repeated disk reads.
- **Compression progress**: Dialog buttons show loading spinner while compressing. Single "压缩" or "全部压缩" (后者仅在 totalImageCount > 1 时可用).

### One-Click Compression (Quick Compress)

- **Purpose**: Shorten the discovery path for image compression. Eliminates the per-image "tap → adjust params → compress" flow for the common case.
- **Settings** (stored in `SettingsProvider`, SharedPreferences):
  - `oneClickCompressEnabled` (bool, default `true`): gates the button and all behavior below.
  - `oneClickCompressMaxLongEdge` (int, default `1536`, range 768–4096, step 256): if an image's long edge ≤ this value, skip entirely (no decode, no re-encode). Rationale: Google Gemini splits images into 768×768 tiles; 2×768 = 1536 minimizes token usage.
  - `oneClickCompressQuality` (int, default `75`, range 50–95, step 5): JPEG quality for re-encoding.
  - `oneClickCompressAlwaysJpg` (bool, default `false`): when true, flatten alpha PNGs to JPEG (white background, non-configurable). When false, alpha PNGs are re-encoded as PNG (preserving transparency).
- **Settings UI**: New section card in Display & Behavior settings (mobile: `display_settings_page.dart`, desktop: `display_pane.dart`), placed after the image cropper toggle. Enabled toggle gates visibility of the other 3 rows (hidden when disabled). Long-edge and quality are sliders with trailing value labels.
- **Button**: Trailing item in the image preview strip (`ListView`), same 64×64 slot as thumbnails. Icon: `Lucide.Zap`. Tooltip: localized `oneClickCompressTooltip`. Visible when `_images.isNotEmpty && oneClickCompressEnabled && !_oneClickCompressing && !_oneClickCompressDone`.
- **Lifecycle**:
  - Tap → button slot becomes `CupertinoActivityIndicator` (64×64), send button disabled, entire strip interaction-locked (no ✕ remove, no size-overlay tap).
  - Iterates ALL `_images` through `ImageCompressor.compressIfNeeded()` with settings params (`maxDimension` = longEdge setting, `quality` = quality setting, `keepPng` = `!alwaysJpg || hasRealAlpha`).
  - Already-compressed images are naturally skipped (longEdge ≤ threshold after first pass). No separate tracking set.
  - On completion: if ≥1 image compressed → aggregate snackbar "已压缩 N 张，节省 X MB"; if zero → "无需压缩". Button vanishes (`_oneClickCompressDone = true`).
  - `_oneClickCompressDone` resets to `false` in `_addImages` (new image arrives → button reappears).
- **Relationship to per-image dialog**: Coexists. The dialog remains available for manual per-image control (full 30–100 quality, arbitrary dimension, explicit format choice). One-click is the fast path; dialog is the precision path.

## Skill System

### Core Concept

- **Skill**: A directory at `<appData>/skills/<name>/SKILL.md` containing a specialized instruction set + optional auxiliary files (scripts/, references/, assets/). The directory name IS the skill's identity — it must match the `name` field in YAML frontmatter and follow AgentSkills naming rules (lowercase letters, digits, hyphens; ≤64 chars; no leading/trailing/consecutive hyphens). Auxiliary files are readable by the model via `read_skill_file`.
- **`SkillManager`**: The facade that owns all skill CRUD. Reads SKILL.md from disk lazily — no memory cache. Atomic write pattern: staging dir → rename target→backup → rename staging→target → cleanup. Path safety: rejects names containing `/`, `..`, leading/trailing dots, and whitespace. Frontmatter parsing uses the `yaml` package (not a hand-rolled line parser).
- **`AppDirectories.getSkillsDirectory()`**: Returns `<appData>/skills/`. Each skill lives in its own subdirectory matching the skill name.

### Lifecycle

- **Import** (three channels, all funnel to `SkillManager.saveSkill()`):
  - Manual paste: User pastes complete SKILL.md (YAML frontmatter + body) into a text box. Real-time frontmatter parsing + name validation.
  - File picker: System file picker selects a single `.md` file or `.zip` archive. ZIPs are scanned for all `SKILL.md` files (any nesting depth), each validated and imported independently.
  - GitHub URL: User pastes a `github.com/{owner}/{repo}[/tree/{branch}[/sub/path]]` URL. App downloads the repo archive ZIP from `github.com/{owner}/{repo}/archive/refs/heads/{branch}.zip` (no API rate limit, no auth for public repos), then reuses the same ZIP import pipeline (scan for all `SKILL.md` at any depth, multi-select dialog if >1 found). If a subpath is specified, the scan is scoped to that subdirectory. Private/missing repos return 404 → localized "not found or private" error. GitHub only — no GitLab/generic git hosts.
- **Update**: Re-import with the same name overwrites the directory. Atomic write handles crash safety.
- **Delete**: `SkillManager.deleteSkill(name)` removes the directory. Removes from all assistants' `skillIds` (orphan cleanup).
- **Export**: Included in backup via `_packZipSync` — `skills/` directory packed independently of `includeFiles`, always included. Incremental backup uses mtime ≥ since filtering (same mechanism as upload/avatars/images/fonts).

### System Prompt Injection

- **`<available_skills>`**: An XML block injected into the system prompt listing only the skills the current assistant has bound. Contains `name` + `description` only (progressive disclosure level 1). Excludes disabled or unbound skills.
  ```xml
  <available_skills>
    <skill>
      <name>pdf-processing</name>
      <description>Extract text and tables from PDF files...</description>
    </skill>
  </available_skills>
  ```

### Tool Layer

- **`load_skill`**: A built-in tool exposed to the model (gated by `assistant.skillIds`). Named to mirror `read_memory` (memory 'tool' mode). Parameter `{ name: string }` (required). Returns XML:
  ```xml
  <skill name="pdf-processing">
    <instructions>
      [SKILL.md Markdown body]
    </instructions>
    <files>
      <file path="scripts/extract.py" size="2150"/>
      <file path="references/api-docs.md" size="8602"/>
    </files>
  </skill>
  ```
  Skills with no auxiliary files omit the `<files>` element. Progressive disclosure level 2: the model sees the file tree only after choosing to load the skill.
- **`read_skill_file`**: A built-in tool exposed to the model (gated by same `assistant.skillIds` as `load_skill`). Parameters `{ name: string, path: string }` (both required). Returns the content of an auxiliary file within a skill directory. Security boundaries: rejects paths containing `..`, absolute paths, and backslashes (forward-slash relative paths only). Binary files → error message. Content capped at 64 KB with `[truncated]` suffix. Progressive disclosure level 3: the model reads specific files on demand after seeing the listing in `load_skill`.

### Assistant Binding

- **`assistant.skillIds`**: `List<String>` on the `Assistant` model, stored in SQLite as JSON (`skillIdsJson` TEXT column, same pattern as `localToolIdsJson`). Only skills in this list are injected into the assistant's `<available_skills>` and have their `load_skill`/`read_skill_file` tool definitions exposed.

### Backup Integration

- `skills/` directory is always included in backup ZIPs — NOT gated by `includeFiles`. Rationale: skill files are small (pure text) and fundamental to assistant behavior. Incremental backup filters by mtime via existing `_addDirectoryToZip(since:)`.
- Restore: `_extractZipSync` decompresses `skills/` entries, preserving mtime from ZIP entry `lastModTime`. `SkillManager` discovers imported skills on next `listSkills()`.

### Relationship to Existing Concepts

- **Skill vs InstructionInjection**: Both provide instructions to the model. **InstructionInjection** follows `memory 'injection'` mode: full prompt is injected into every system message regardless of relevance. **Skill** follows `memory 'tool'` mode: only metadata (name/description) is injected; the model must choose to call `load_skill` to read the full body. This is the key structural distinction — `InstructionInjection : injection mode :: Skill : tool mode`.
- **Skill vs WorldBook**: **WorldBook** entries are triggered by keyword/regex matching against conversation context and injected at specific positions (after system prompt, top of chat, bottom of chat, at depth). **Skill** has no keyword triggering — the model decides based on the `<available_skills>` descriptions.
- **Skill vs LocalTool/MCP**: **LocalTool** and **MCP** are executable tools: model calls them → something happens (read clipboard, execute code). **Skill**'s `load_skill` is a "knowledge tool": model calls it → receives instruction text → nothing executes. Same tool dispatch pathway, different semantics.

## Time Injection (Cache-Aware)

- **Time Injection**: A per-assistant feature (`Assistant.enableTimeInjection`, default off) that appends a timestamp to every user message in the API payload at build time. Ephemeral — never persisted to DB, never shown in chat UI. The timestamp is derived from the message's immutable `ChatMessage.timestamp`, so historical messages produce byte-identical output across requests on a device with a stable timezone, preserving the LLM provider's prompt cache prefix. Note: the timestamp uses device-local time without a UTC offset; if the device timezone changes, historical timestamps resolve to different local components and the cache prefix will invalidate.
- **`<time-note>`**: A hardcoded English model instruction appended at the very end of the assembled system message (after all other injections). Tells the model that timestamps follow each user message. Static content — does not invalidate cache.
- **Timestamp format**: `\n\n(Mon 25-07-26 14:03:22)` — abbreviated English day name, compact date with hyphens, local time (device timezone, no UTC offset). Appended after all other user message processing (markers, doc extraction, OCR, regex transforms).
- **Message template bypass**: When enabled, `applyMessageTemplate()` is skipped entirely. The two features are mutually exclusive by design — the template's `{{ time }}`/`{{ date }}` variables use volatile `DateTime.now()` and would defeat the cache goal.
- **Preset messages**: Excluded (`isPreset` check). Canned conversation starters are structural scaffolding, not real temporal events.
- **Volatile variable warning**: On toggle-on, a one-time dialog scans `assistant.systemPrompt` for `{cur_date}`, `{cur_time}`, `{cur_datetime}` and `assistant.memoryRecordPrompt` for `{current_hour}`, `{current_date}`, `{current_datetime}`. Lists only variables actually present. Skipped entirely if none found. Informational only — no enforcement.
- **Delta** (deferred): A "since last message" duration suffix was considered but deferred. If added later, it would also be derived from stored timestamps (cache-stable).

### Example Dialogue

> **Dev:** "A user pasted a long workflow prompt into InstructionInjection expecting the model to use it only when working on that specific task. Should this be a Skill instead?"
> **Domain expert:** "Correct. InstructionInjection always injects into every system prompt — it's `memory 'injection'` mode. The model gets that prompt unconditionally, even for unrelated queries. Skill only exposes its name and description in `<available_skills>`; the model reads the full body only when it calls `load_skill`. This way the instruction stays out of context until it's actually needed."

## Custom Request Layers (Headers & Body)

- **4-layer merge order** (last wins on key collision):
  1. `providerDefaultHeaders` — hardcoded per provider type (e.g. OpenRouter `X-Title`)
  2. **Provider-level** — `ProviderConfig.customHeaders` / `.customBody` (applies to all models under the provider)
  3. **Model-level** — `ProviderConfig.modelOverrides[modelId]['headers']` / `['body']` (per-model override)
  4. **Assistant-level** — `Assistant.customHeaders` / `.customBody` (per-assistant, passed as `extraHeaders`/`extraBody`)
- **Merge semantics**: Shallow (`Map.addAll`). A later layer replaces the entire value for a colliding top-level key. Deep/nested merge is NOT supported (upstream issue Chevey339/kelivo#804).
- **Data format**: `List<Map<String, String>>` — headers use `{name, value}` keys; body uses `{key, value}` keys. Consistent across all layers.
- **No guardrails**: Users may set any header key (including `Authorization`, `Content-Type`). Power-user responsibility.

## MCP Tool Prefix (Name Disambiguation)

- **Tool Prefix**: A per-server string (`McpServerConfig.toolPrefix`) prepended to all tool names from that MCP server when building the tools array for the LLM API. Format: `{prefix}_{originalName}`. Charset: `[a-zA-Z0-9_]`, max 16 chars, no leading digit. Default: empty (no prefix). Server-level, not per-assistant.
- **Collision**: Two tool definitions sharing the same `function.name` in a single API request. Causes the LLM API to reject the entire request (not silent shadowing). Two sources: MCP-vs-built-in (e.g. MCP `create_memory` vs built-in `create_memory`) and MCP-vs-MCP (two servers exposing the same tool name).
- **Collision detection**: Performed at send time, scoped per-assistant (depends on which built-in tools the assistant has enabled AND which MCP servers are bound). Hard-blocks the send with a guidance dialog.
- **Resolution dialog actions**:
  - MCP-vs-built-in: disable the built-in for this assistant / unbind the MCP server from this assistant / add a prefix to the MCP server.
  - MCP-vs-MCP: unbind one of the conflicting servers / add prefixes to ≥ N−1 of the N conflicting servers.
- **Prefix validation**: At save time, checks `prefix.length + 1 + maxToolNameLength ≤ 64` (OpenAI function name limit). Rejects with inline error if overflow.
- **UI display**: Tool-call cards show the as-called (prefixed) name. No stripping in the UI layer.
- **Settings access**: Prefix is also editable proactively in the MCP server detail UI, independent of any collision.

## Storage Space Management (Enhancements)

- **占用空间 (occupied space)**: The logical file size in bytes (`StorageFileEntry.bytes`), as reported by the OS. NOT disk block allocation. "Sort by occupied space" and "sort by size" are the same single sort key.
- **引用计数 (reference count)**: The number of chat messages whose content references a file's path (same extraction logic as `_cleanupOrphanUploads` in `chat_service.dart`). refCount=0 means "orphaned" — consistent with existing orphan-cleanup semantics.
- **Draft exclusion**: Unsent input-draft / pending-input-bar references do NOT count toward refCount. The persisted draft (`chat_draft_v1`) is always in sync with the in-memory input bar, so it is the single source for the deletion guardrail below.
- **Deletion guardrail**: When deleting a refCount=0 file, the delete path cross-checks the persisted draft. If the file is still referenced by the unsent draft, the confirm dialog is enriched with a warning but deletion is still allowed (warn-and-allow, not block). Rationale: a stale/abandoned draft should not trap the user; the user retains final authority.
- **引用计数与反向定位同源**: refCount and reverse-locate are derived from ONE scan that builds `path → List<location>`, where each location records `conversationId`, `conversationTitle`, `messageId`, and a short message preview. `refCount = locations.length`. Never scan twice.
- **引用计数计算时机 (triggered-on-demand)**: The refCount scan is a CPU-bound synchronous full-message pass (same shape as the stats page read, which stutters the UI ~0.5s). It is NOT run on page load. It is triggered on demand by either (a) turning on the "只看无引用" orphan filter, or (b) tapping a file to view its references. A loading indicator covers the ~0.5s. The result is cached for the session and invalidated on manual refresh and after any deletion. Rationale: refCount is a secondary cleanup feature; the common path (glance at usage / clear cache) must stay fast. Size (`StorageFileEntry.bytes`), by contrast, is cheap (from the file stat) and is always available on load — so size is shown eagerly while refCount is on-demand.
- **图片占用空间显示**: Image tiles in the storage grid show file size as an always-visible bottom gradient overlay (mirrors the chat input bar pattern, `chat_input_bar.dart:1906`). Size is eager (cheap, from the file stat). The refCount badge is a SEPARATE corner badge that appears only after the on-demand scan — size (bottom, eager) and refCount (corner, on-demand) never conflict. File rows already show size in their subtitle; they only gain a trailing refCount label after the scan.
- **排序 (sorting)**: A single sort dimension toggle — [按大小 | 按时间] — in the `_UploadManager` actions row, applying uniformly to the image grid and the file list. Sorting is client-side over the already-loaded `_entries` (which carry `bytes` and `modifiedAt`); no re-fetch. Default is 按时间 desc (preserves current behavior). Each mode defaults descending (largest/newest first — the cleanup-useful order); tapping the active segment flips asc↔desc with an arrow indicator. "Sort by occupied space" and "sort by size" are the SAME 按大小 mode. The segment control is a page-private widget (no shared segmented control exists in the repo); per explicit request it carries a comment noting it is intentionally page-local and should be extracted to `shared/widgets/` only if reused elsewhere.
- **反向定位 (reverse locate)**: Cross-conversation. Mirrors the global full-text search click-to-locate UX (result list grouped by conversation title + message preview; tap to jump). Reuses `HomePageController.openGlobalSearchResult({conversationId, messageId})` (`home_page_controller.dart:629`), which switches conversation, scrolls to the message, and flash-highlights it via the spotlight mechanism. NOT restricted to the current conversation — the intent is "which chats use this file?".
- **Cross-tab wiring (stopgap)**: `HomePageController` is page-private (built in `_HomePageState.initState`, entangled with a page-owned `ChatAutoFollowScrollController`), not in the root Provider tree. The Storage page reaches it via a new singleton payload bus `MessageLocateBus` (mirrors `DesktopSettingsNavigationBus`), carrying `{conversationId, messageId}`. Desktop: `DesktopHomePage` also listens and switches to the Chat tab. Mobile: fire the bus then `Navigator.pop` back to the alive chat route. This is a DOCUMENTED STOPGAP — the long-term direction is promoting `HomePageController` to a root provider and deleting the bus. See `docs/adr/0005-storage-reverse-locate-bus-stopgap.md`.

### Safety boundaries & edge cases

- **孤儿检测限定 `upload/` (DATA-SAFETY)**: Message content has TWO coexisting local-file reference syntaxes: the marker syntax `[image:]`/`[file:]` (parsed by `_extractAttachmentPaths`) AND standard Markdown `![alt](path)` (written by `MarkdownMediaSanitizer` for LLM inline images under `images/`, plus assistant images referenced by assistant config, plus theoretically user-authored Markdown links). The extractor sees ONLY markers. Therefore orphan detection + the "只看无引用" filter + orphan bulk-delete are restricted to **`upload/` files only** (matching the proven `_cleanupOrphanUploads` scope). `images/` files are EXCLUDED from orphan deletion; their refCount is best-effort informational only (under-counts Markdown/config refs) and must never drive a delete decision in the UI. Markdown-reference parsing is a documented DEFERRED task. See `docs/adr/0006-refcount-marker-only-upload-scope.md`.
- **路径规范化 (must-get-right)**: The reference scan MUST reuse `_cleanupOrphanUploads`'s `canon()` (normalize + Windows lowercase) and apply `SandboxPathResolver.fix()` to message paths, comparing against canonicalized on-disk paths. Otherwise iOS sandbox-container path changes across app updates and Windows case-insensitivity produce mass false orphans.
- **版本计数**: refCount counts ALL message versions (not just the visible/selected version), matching `_cleanupOrphanUploads` which iterates every message. This keeps "refCount=0 ⟺ the existing cleanup would delete it" true. Consequence: reverse-locate navigates via collapsed (visible) messages, so locating a reference that exists only in a hidden version switches to the conversation but may not scroll precisely (best-effort; `scrollToMessageId` returns early if the target isn't among collapsed messages).
- **删除已引用文件的警告**: The delete-confirm dialog is enriched when any selected file has refCount > 0 (and counts are computed): it states how many selected files are referenced by messages and that deleting breaks their display. Mirrors the draft guardrail (warn-and-allow).
- **扫描须让出 isolate**: The on-demand scan is CPU-bound; a tight synchronous loop would freeze the UI AND freeze the loading spinner. The scan loop must yield periodically (e.g. `await` every ~200 messages) so the spinner animates and the UI stays responsive. A guard flag prevents concurrent scans from rapid filter toggles.
- **Trivially handled**: sort tie-break by name (deterministic); refCount dedupes within a message (count = number of messages, not occurrences); missing `upload/`/`images/` dirs handled as today; a draft-only file shows refCount 0 but the delete guardrail warns (no separate "草稿" badge — YAGNI).

## LAN Sync (Local Network Device Sync)

- **LAN Sync**: A device-to-device sync mechanism over the local network (no cloud). Two devices exchange incremental backup ZIPs and merge-restore them. NOT a backup target — it's a peer-to-peer data transfer that reuses the existing incremental backup + merge restore infrastructure.
- **Sync Plan**: The result of comparing per-conversation messageId lists between two devices. For each conversation present on both sides, determines a **fork point** (last common messageId by `messageOrder`) and a three-state classification. See `docs/adr/0010-lan-sync-two-round-trip.md`.
- **Fork Point**: The last common messageId within a single conversation, identified by per-conversation messageId list comparison (NOT a global timestamp). All messages after this point in each device's copy are "increments". Different conversations may have different fork points.
- **Fork (divergence)**: A three-state classification per conversation: (1) only device A has increments → B imports; (2) only device B has increments → A imports; (3) both have different increments → fork. v1 detects forks but does not resolve them (future: keep both copies via a new conversation with `forkedFromId`).
- **Sync `since`**: A single `DateTime` derived as the minimum timestamp across all per-conversation fork points. Used as the `since` parameter for the existing incremental backup zip creation. Over-inclusive by design — merge restore deduplicates by message ID. Per-conversation messageId comparison is the protocol-layer mechanism; `since` is the transport-layer mechanism. They are orthogonal: fork detection works regardless of how the zip is built.
- **Two Round Trips**: The sync protocol. Round 1: initiator POSTs its index → server returns sync plan. Round 2: initiator POSTs its incremental zip → server responds with its incremental zip. Only the server needs to listen; the initiator is a pure HTTP client. Both sides apply + restart independently after the transfers complete — no cross-device ACK.
- **Sync scope**: Chats (conversations + messages + toolEvents + geminiThoughtSigs) + referenced files (via `since` mtime filter) + missing assistants (set difference, existing assistants untouched). Settings (provider configs, MCP servers, etc.) are NOT synced — they are device-level configuration.
- **Backup time independence**: `BackupReminderProvider.lastBackupTime` is NOT updated after sync. Regular incremental backups continue from their last regular backup timestamp. Sync and backup timelines are fully independent.
- **PIN**: A 4-digit random code (0000–9999) generated at server startup, shown in the server UI, validated per-request via `X-Sync-Pin` header. Not persisted. Protects against accidental connections on shared networks, not a security mechanism against attackers.
- **Single-use lifecycle**: The HTTP server is started for one sync operation. After the transfers complete, both devices merge-restore and restart — the server dies with the process. The server does not stay resident.

### Flagged Ambiguities

- "skill" was used interchangeably to mean both "a set of instructions loaded from disk" and "an individual step in a model's reasoning process" — resolved: the former is **Skill** (capitalized, bounded in the codebase), the latter falls under general LLM domain language and is not part of Cuplivo's domain model.

## Deletion Recovery & Remote-Deletion Markers

### Core Concepts

- **deleted_records**: A Drift table (`DeletedRecordRows`) holding recoverable payloads for locally-deleted entities. Each row = one top-level entity bundle (conversation bundle includes its messages + toolEvents + geminiSigs + MCP server links; message bundle includes its toolEvents/sigs). `size` column = `bytes(utf8(recoveryJson)) + 256` (covers DB row overhead). NOT backed up — excluded structurally (backup export never queries this table). 10 MB default cap, user-configurable. See `docs/adr/0011-deletion-recovery-two-table-split.md`.

- **deletion_markers**: A Drift table (`DeletionMarkerRows`) holding id-only tombstones for sync/backup, with no payload. Two origins share one table:
  - `origin='local'`: written on every local delete (dual-write with `deleted_records`). Source of `deleted.json`.
  - `origin='remote'`: written when a sync peer or backup's `deleted.json` declares an id that still exists locally. UI marks these as "远端已删除" and offers one-click local deletion.
  - Unified 5000-row FIFO by `deletedAt`, regardless of origin.

- **Echo avoidance**: `deleted.json` is generated from `origin='local'` rows only. A remote marker is never echoed back — A deletes X → syncs to B → B stores `origin='remote'` row → B's `deleted.json` excludes it → A never receives its own deletion as a foreign declaration.

- **deleted.json**: Optional payload in LAN sync round-2 zip AND backup zip. Contains `{type: [{id, deletedAt}, ...]}` grouped by entity type, capped at 5000 entries/type. Sourced only from `origin='local'` rows. Absent in old-format payloads → receiver treats as "no deletions declared" (backward compatible, no protocol bump).

### Recovery Granularity

- **Bundled per top-level entity**: 1 `deleted_records` row = 1 top-level entity. Conversation bundle nests all messages + toolEvents + geminiSigs + MCP server links. No 二级展开 in UI.
- **7 recoverable types**: conversation, message, assistant, worldBook, quickPhrase, mcpServer, memory. Skill is NOT recoverable (filesystem entity, physical delete).

### Deletion Path Policies

- **clearAllData**: writes NEITHER `deleted_records` NOR `deletion_markers`. Fully destructive, no local recovery, peer-blind. See `docs/adr/0012-clearalldata-no-tombstone-blind-peer.md`.
- **deleteAssistant cascade**: full cascade trash — 1 assistant-trash row + N conversation-trash rows. UI groups the N+1 rows by original assistantId.
- **Orphan message restore**: refused if parent conversation no longer exists live.
- **Orphan conversation restore**: refused if `assistantId` points to a deleted (and not simultaneously restored) assistant.

### Restore Position Semantics

- **messageOrder is a snapshot, not a restore target**: `message_rows.messageOrder` is compacted (`_compactMessageOrder`) on every delete. A deleted message's original `messageOrder` is stale by restore time. The bundle stores `messageId` + `groupId`/`subgroupId`/`version` for identity, NOT `messageOrder` for position.
- **message restore = append**: restored messages are appended to the parent conversation's end (`messageOrder = max + 1`). Trash restores content, not exact timeline position.
- **Best-effort file restore**: `_cleanupOrphanUploads` keeps its current behavior (deletes files no longer referenced by live conversations). A restored conversation's JSON may reference already-deleted upload/avatar files. UI warns at restore time.

### Quota & Eviction

- **deleted_records cap**: default 10 MB, user-configurable via discrete dropdown (mirrors log-max-size pattern), SharedPreferences key `trash_cap_mb_v1`. Options `[1, 5, 10, 25, 50, 100, 200, 500, 0]` MB (0 = unlimited).
- **Eviction rule**: evict oldest by `createdAt`, NEVER self-evict the current write batch (identified by `batchId` column).
- **deletion_markers cap**: unified 5000-row FIFO by `deletedAt`, not user-configurable.

## Handoff (Sub-Agent Delegation)

### Core Concepts

- **Handoff**: A fire-and-forget delegation where one assistant (the source) launches another assistant (the target) in a new conversation with a task prompt. The source model receives only the new conversation's UUID as the tool result — no sub-agent output is collected. The sub-agent runs with full tool access (MCP, local, memory, search). The user navigates to the sub-conversation manually.
- **`@kelivo/subagent`**: An in-memory MCP server (same pattern as `@kelivo/fetch`) that exposes one tool: `handoff(assistant, task)`. Auto-created at startup, non-deletable, toggleable via `isActive`. Per-assistant binding via `mcpServerIds` controls which assistants can delegate — don't bind the server, can't hand off. There is no dedicated `handoffDisabled` field.
- **`HeadlessGenerationService`**: A root-level provider that owns sub-generations. Runs the full generation pipeline (system prompt, tools, streaming, persistence) detached from any page controller. Exposes `start()`, `isActive()`, `chunkStream()`, `cancel()`. Uses the `contextProvider` pattern to reuse `ToolHandlerService`. Cancellation goes through the existing `ChatApiService` token registry — no new cancel path.
- **Discoverable**: A per-assistant boolean (`Assistant.discoverable`, default false). When true, the assistant appears as a valid handoff target in the `@kelivo/subagent` tool description. The target declares itself; the source does not maintain a target list.
- **`handoffId`**: A per-assistant readable handle (`[a-z0-9-]`, max 32 chars, unique across all assistants). Used as the `assistant` parameter value in the handoff tool call. Required when `discoverable == true`. Validated at save time (same pattern as skill name validation).
- **`handoffDescription`**: A per-assistant free-form string injected into the handoff tool's description at connection time. Tells the calling model when to delegate and what prompt format to use.
- **`parentConversationId`**: A nullable column on `conversations`. Set when a conversation is created by a handoff. Enables bidirectional navigation bars. Orphan reference (parent deleted) → backward bar simply doesn't render.

### Tool Semantics

- **No enum, call-time validation**: The `assistant` parameter is a free-form string. The tool description lists available targets (built at connection time, may go stale). The handler validates at call time: no match or not discoverable → error string with available targets listed. Zero discoverable assistants → error string explaining the situation. The model self-corrects from the error (same pattern as MCP tool errors via `_renderToolErrorForModel`).
- **Task-only context**: The sub-conversation receives exactly one user message: the `task` string. No history from the parent conversation is injected. The calling model is responsible for including all necessary context in the task.
- **Recursion**: Allowed with no depth limit. A sub-agent that has `@kelivo/subagent` bound and can see discoverable assistants may hand off again. The user is watching (they navigated to the sub-conversation) and can cancel.
- **Outer stream lifecycle**: After the handoff tool returns the UUID, the outer model generates a farewell message naturally. The outer stream is not cancelled. The farewell persists in the parent conversation.

### UI

- **Forward bar**: On the assistant message containing the handoff tool-call card, a tappable chip showing "{target assistant name} · {first 4 chars of child conversation ID}". Tap navigates to the child conversation.
- **Backward bar**: On the first user message of a handoff-spawned conversation, a tappable chip showing "← {parent assistant name} · {first 4 chars of parent conversation ID}". Tap navigates to the parent. Edge case: if the first user message is deleted, the backward bar is not shown.
- **Conversation list badge**: A small icon (e.g. `Lucide.CornerDownRight`) on conversation list tiles where `parentConversationId != null`.
- **Page subscription**: On `switchConversationAnimated(convId)`, the page checks `HeadlessGenerationService.isActive(convId)`. If active, subscribes to `chunkStream(convId)` and drives the existing `StreamController` from those chunks. On navigate-away, unsubscribes (generation continues, persists to DB). On return, re-attaches or loads the finalized message.

### Relationship to Existing Concepts

- **Handoff vs Multi-AI Comparison**: Multi-AI sends the same prompt to N models in parallel within one conversation (subgroupId cards). Handoff creates a separate conversation with a different assistant and a model-formulated task. Multi-AI is comparison; Handoff is delegation.
- **Handoff vs ProactiveCare**: ProactiveCare is scheduled autonomous generation by a single assistant (no tools, no user interaction during generation). Handoff is model-initiated delegation with full tools and user interaction (approval, ask_user) available in the sub-conversation.
- **Handoff vs MCP tools**: Handoff IS an MCP tool (`@kelivo/subagent`), but its effect is to launch a full agent (another assistant with its own tools), not to perform a single atomic action. The MCP protocol is the delivery mechanism; the semantic is agent delegation.

### Example Dialogue

> **Dev:** "The user asked the orchestrator to research a topic AND write code. The orchestrator called `handoff` twice — once to `research-bot` and once to `code-helper`. Where do the results go?"
> **Domain expert:** "Each handoff creates a separate conversation. The orchestrator's conversation gets two tool-call cards, each with a forward bar chip. The user navigates to each sub-conversation independently. The orchestrator never sees the sub-agents' output — it only got the UUIDs back. If you need the orchestrator to synthesize results, that's a future `startAndWait()` mode, not v1."

### Flagged Ambiguities

- "subagent" was used interchangeably with "handoff target" and "child assistant" — resolved: the feature is called **Handoff** (the act of delegation). The target is simply "the target assistant." There is no persistent "subagent" entity — the sub-conversation is a normal conversation with a `parentConversationId`.

## Multi-Assistant Group Chat (多助手群聊)

- **Director (导演)**: The single model that decides the speaking order in a group chat. It never speaks to the user directly — it only calls `select_speaker` / `end_turn`. Implementation lives in `lib/features/group_chat/services/director_runner.dart`; the controller class `GroupChatOrchestrator` is implementation detail, NOT a domain term.
- **Round (轮)**: The speaking cycle that starts with a user message and ends when the Director calls `end_turn`. One round contains 1 user turn + 0..N assistant turns (N ≤ the per-round assistant message cap). Hitting the cap only *pauses* the round — `end_turn` is the round's only true endpoint.
- **Turn (回合)**: One message in the Director session. E1 = user turn, E2 = assistant turn, E3 = cap-resume turn (pending capped assistant content merged with the next user message). E1/E2/E3 are code labels only; the domain term is "turn".
- **Public transcript (公开记录)**: The member-visible message stream — `Conversation` (kind=group) + `MessageRows.speakerAssistantId`. It is a normal input to the regular message pipeline (context building, memory, backup conversations/messages sections, trash conversation restore).
- **Director session (导演会话)**: The Director's private working stream — NOT persisted. Each director call is rebuilt from the public transcript (E1/E2/E3 prompt wrappers assembled on the fly); the "导演日志" page is a placeholder noting the session is ephemeral. The v13 `director_message_rows` table was dropped in schema v14; backup/trash carry no director section (rebuilt from the restored public transcript). **The two streams never mix**: public-transcript consumers must never see director rows.
- **Director call protocol**: One call = one decision. The first valid `select_speaker` / `end_turn` is final: the stream is cancelled immediately and every tool result is a neutral `{"ok":true}` — never "ignored" (a model reads "ignored" as a rejected call and retries in a loop). All transcript turns are sent with role `user` (E1/E2/E3 are context fed to the Director, not Director speech — deliberate).
- **Roster (名册)**: A snapshot of the group's member assistants (id/name/persona) injected into the Director context per the injection mode. Membership caps: soft 12, hard 20 (invites beyond the hard cap are rejected).
- **Injection mode (注入模式)**: Where/when the roster is injected into the Director context — 7 modes: before system prompt, appended into system prompt, end of first user turn, end of every user turn, end of every user+assistant turn, every N user turns, every N user+assistant turns.
- **Speaker (发言者)**: The assistant the Director selects to speak this turn. Public transcript messages are tagged with `speakerAssistantId`; user messages carry none.
- **Cap (轮次上限)** / **pending cap message (封顶待续消息)**: The per-round assistant message limit (`maxAssistantMessagesPerRound`, default 3). When the cap is hit, the last assistant message becomes the pending cap message and is merged into the next user message's E3; the round pauses rather than ends.
- **Context boundary (上下文边界)**: `Conversation.truncateIndex` — a raw-space index (normal chat semantics) marking where the model context starts. It applies to BOTH the member private contexts (raw→collapsed mapped via `ChatService.rawToCollapsedSkip`) and the Director context (rebuilt history is sliced the same way). Cleared/reset via the input bar's "清空上下文" (toggle at tail).
- **conversation kind (会话类别)**: The `Conversation` discriminator — `normal` (regular conversations, including 1:1) or `group` (a group chat's public transcript). Group conversations have no single owner assistant (`assistantId = null`) and link to their `GroupChat` 1:1 via `conversationId`. Regular conversation lists exclude group by default (`getAllConversations(includeGroup: false)`); `includeGroup: true` is only for backup inventory / admin surfaces.

### Relationship to Existing Concepts

- **vs Multi-AI Comparison (多 AI 对比)**: Multi-AI sends the same user message to N models in parallel (subgroupId cards) — no Director, no private member context. Group chat is sequential orchestration: the Director picks one speaker per turn, and each member assistant gets a privately rewritten context. Parallel comparison vs sequential orchestration — orthogonal features; an assistant can participate in both.
- **vs Handoff (交接)**: Handoff is model-initiated fire-and-forget delegation creating a separate child conversation (`parentConversationId`). Group chat is a user-initiated persistent session mediated by the Director, with all speech landing in one public transcript. Model-initiated vs user-initiated.
- **vs ProactiveCare (主动关怀)**: ProactiveCare is scheduled autonomous generation by a single assistant with no tools. Group chat is on-demand, multi-assistant, Director-orchestrated.
- **vs regular 1:1 conversation**: A group chat IS a conversation (`kind=group`) — just without an owner assistant, plus a `GroupChat` entity and a Director session alongside.
- **Membership**: An assistant can be a member of multiple groups; deleting an assistant removes it from all groups' membership (`removeAssistantFromAllGroups`). Its historical speeches remain in public transcripts — intentional.

### Flagged Ambiguities

- "orchestrator" was used informally in the Handoff example dialogue (the delegating assistant) and as part of the controller class name `GroupChatOrchestrator` — neither is a domain term. The domain term for the group-chat decision-making model is **Director**.

## MCP OAuth (v2, automated)

- **OAuth 授权流程 (authorization flow)**: The flow for connecting a remote MCP server that requires OAuth. v2 is AUTO-first: the user enables the switch and taps 开始授权 — the app auto-discovers the authorization server metadata (RFC 8414, `{origin}/.well-known/oauth-authorization-server`), auto-registers a public client (RFC 7591 DCR, `token_endpoint_auth_method: none`), and starts a loopback callback server (RFC 8252) so the browser redirect lands back in the app. Manual paste is the fallback. See `docs/adr/0016-mcp-oauth-auto-flow.md`.
- **Loopback callback**: `OAuthLoopbackServer` binds `127.0.0.1:0` (random port, mirrors `LanSyncServer` bind pattern). Client registration registers the portless `http://127.0.0.1/callback` + `urn:ietf:wg:oauth:2.0:oob`; at authorize time the redirect URI carries the random port (server must accept the loopback port-wildcard rule — verified against Tavily). One request answered, then the port is released.
- **Degradation chain** (silent, no user choice): discovery fails → manual endpoint entry (advanced config); no registration endpoint or registration rejected → manual client ID; loopback bind fails → paste mode. The paste field always accepts code or full URL and validates CSRF `state`.
- **McpOAuthConfig**: A nested app-level DTO on `McpServerConfig` (`authorizationEndpoint`, `tokenEndpoint`, `clientId`, `clientSecret?`, `scopes`, `redirectUri?`). NOT the library's `OAuthConfig` — converted at connection time. Discovered endpoints and registered client IDs are persisted back into these fields after a successful `beginFlow`, so the next run starts fully configured. Empty fields are legal — auto flow fills them.
- **Token persistence**: `OAuthToken` stored inside `McpServerConfig` JSON (SharedPreferences). v1 only — a secure-storage refactor (Keychain/Credential Manager) is planned; the persisted shape stays compatible. Tokens ARE included in backups (settings.json round-trip) until the security refactor changes this.
- **Token refresh**: Reuses the vendored library's built-in proactive refresh (`OAuthTokenManager` timer / SSE 80%-lifetime timer). The library gains a persistence hook so refreshed tokens are written back to `McpServerConfig`. No reactive 401-retry layer in v1. Refresh failure surfaces as the standard `McpStatus.error` on the server card → "需要重新授权".
- **Re-auth**: The server card error state IS the re-auth entry point — error text says re-authorization is needed; the edit page's OAuth section hosts the flow. No blocking dialogs mid-conversation.
- **OAuth section UI**: Switch-gated in the edit page (mobile sheet + desktop dialog), placed right after the server URL (it is connection config, not an advanced setting). When enabled: status row (authorized/unauthorized + clear token) → primary [开始授权] button → collapsed "高级配置" (endpoints/clientId/secret/scopes/redirectUri — only needed when auto-discovery fails). Saving with the switch off clears BOTH config and token (`clearOauth` + `clearOauthToken`).
- **Header precedence**: When OAuth is enabled, the Bearer token overwrites any manual `Authorization` header from `McpServerConfig.headers` (natural library behavior: merged headers first, token written last). No save-time validation.
- **Flow state**: PKCE verifier + `state` + loopback server live in `OAuthFlowService` (`lib/core/services/oauth/oauth_flow_service.dart`) in memory only, keyed by serverId. An app restart mid-flow invalidates them — the user restarts the flow. Normal restarts need no user action: the persisted token is injected via `setOAuthToken` at connect. The service is provider-agnostic: a future OAuth LLM provider (e.g. xAI) reuses the flow + loopback + DCR machinery.

## Schema Self-Heal (schema 自愈)

- **Schema Self-Heal**: A runtime repair on every database open: checks that every column/table added by migrations actually exists and adds whatever is missing. Exists because migration steps wrap `ADD COLUMN` in silent error-swallowing for idempotent replay — a genuinely failed step leaves `user_version` advanced while the column stays missing, and later upgrades never re-run the failed step. Real users hit this on schema v8 (`is_preset`) and v12 (`discoverable`/`handoff_*`); such DBs reach the current schema with a permanent gap that only the heal can close. See `docs/adr/0017-schema-self-heal.md`.
- **Heal boundary**: Covers everything added by the v5–v13 migrations. `director_message_rows` is deliberately NOT healed — schema v14 dropped it (the Director session is ephemeral, rebuilt from the public transcript).

## Network Request Logging

- **Request log (请求日志)**: The per-day request/response log file `logs/logs.txt` (daily rotation, size cap, auto-delete). All categories interleaved in one file; entries carry a category tag.
- **Categories**: Four independent logging categories — **LLM** (reuses `request_log_enabled_v1`), **MCP**, **TTS**, **Search** (new keys, default off). Tags: `[REQ n]` / `[RES n]` (LLM, bare), `[MCP REQ n]` / `[MCP RES n]`, `[TTS REQ n]` / `[TTS RES n]`, `[SRCH REQ n]` / `[SRCH RES n]`. Request IDs come from one shared counter, unique across categories (the log viewer keys entries by ID).
- **JSON-RPC-layer logging**: MCP traffic is logged at the JSON-RPC message layer — method, params, result, error — not the HTTP layer. MCP entries therefore carry no URL and no HTTP status code. Uniform across SSE / Streamable HTTP / stdio / in-memory transports. See `docs/adr/0017-json-rpc-layer-mcp-logging.md`.
- **saveOutput (保存响应输出)**: A volume gate on response/result bodies — not a privacy switch. When off: LLM response chunks, Search response bodies, and MCP list-method results (`tools/list`, `resources/list`, ...) are omitted. Request bodies (including LLM request bodies that contain user messages) and MCP `tools/call` results are always logged.
- **Audio-body exemption**: TTS success response bodies are never logged — every provider returns audio, either as raw bytes (OpenAI, Groq, xAI, ElevenLabs) or base64 embedded in JSON/SSE (Gemini, Qwen, MiMo), which a content-type rule alone cannot catch. TTS error response bodies are always logged.
- **Write-time suppression**: Repeated MCP failures are suppressed at write time, keyed per server, deduplicated by `code|message`, capped at 20 distinct entries per server. The suppressed set flushes as a one-line summary on the next successful message from that server, on disconnect, or on cap overflow. No periodic timer.
- **Heartbeat**: The app's per-server liveness check is a tagged `tools/list` JSON-RPC call every 12 seconds. Successful heartbeat calls (and their rate-limit failures) are suppressed from the log; real failures are logged. Steady-state MCP logs show only real traffic and errors.
- **Known limitation**: MCP log entries are labeled by `server.name`, and per-server suppression state is keyed by that label — two servers sharing the same user-entered name share log state (log-id pairing and suppression sets). Log-only impact, accepted for label readability.

## Reading Mode (阅读模式)

- **Reading Mode**: A per-message, full-screen reading view for long assistant answers, opened from the message "More" menu (`MessageMoreAction.readingMode`, Lucide.BookOpen icon) — both the mobile bottom sheet and the desktop context menu. Also available on Multi-AI card messages (card `hideActions` does not hide it).
- **Gate**: Assistant-only (`role != 'user'`), non-streaming, and `visualContent.length > 800` chars (`kReadingModeMinChars` in `lib/features/chat/utils/message_visual_content.dart`). Computed inside `showMessageMoreSheet`, so every invocation site gets it for free. User messages never show the entry.
- **Content**: Renders `messageVisualContent()` — the same renderer-consumed string as the chat bubble: legacy `<think>` blocks stripped unless structured reasoning is present (`reasoningText` non-empty, or `reasoningSegmentsJson` parses to a NON-EMPTY segment list — `[]` / `segments:[]` / malformed payloads count as absent), then assistant visual regex transforms (`AssistantRegexTransformTarget.visual`). Copy-all in the reader toolbar copies this same string (WYSIWYG), NOT raw `content`. The shared function deliberately mirrors `ChatMessageWidget._buildAssistantMessage`'s inline pipeline — change both together.
- **Assistant resolution**: The reader resolves the regex-transform assistant itself via `assistantForMessage()` (speaker `speakerAssistantId` → conversation `assistantId`, null on failure), mirroring `ChatMessageWidget._assistantForMessage` — so every entry point (chat list AND Multi-AI cards) applies the same transforms as the bubble. The toolbar title is the caller-supplied `assistantName` (speaker-aware for group chats), falling back to the resolved assistant's name, then a localized fallback.
- **Typography**: 18px base / 1.75 line-height, centered content column capped at 720px. Font −/+ (14–24, step 2) scales the WHOLE content area — code blocks and tables included — via `TextScaler.linear(systemScale × readerSize/18)`, the same mechanism as the chat list's font scale. Heading sizes (h1–h6) scale proportionally with the base font (`MarkdownWithCodeHighlight._headingTextStyle`, anchored at 15.5 so chat/export output is unchanged) — otherwise fixed heading sizes would collapse against the reader's larger body. The reader size is an absolute int, independent of `chatFontScale` (a relative multiplier), persisted as `reader_font_size_v1` (default 18), adjustable only in the reader toolbar (no settings-page row).
- **Toolbar**: Back + assistant name + copy-all + font −/current size/＋. The name is the caller-supplied `assistantName`, with a localized fallback when none resolves (e.g. deleted assistant).
- **Presentation**: `Navigator.push` on ALL platforms, including desktop — a deliberate deviation from the sidebar-switching convention. See `docs/adr/0017-reading-mode-desktop-route-push.md`.
