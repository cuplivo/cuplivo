# Changelog

## [2.6.3] - 2026-08-08

> ℹ️ Android users please note: the in-app auto-update previously always downloaded the x86_64 build; this has been fixed, but to obtain this version you still need to grab the arm64-v8a APK from the GitHub Release page.

### Added

- Migrate from RikkaHub: import backups converted to the Cuplivo-compatible format via the migration website (#165)
- Built-in filesystem enhancements: browse mounted directories in an in-app file browser; grep results now return paginated matches with surrounding context; inspect code structure via `kelivo_outline`; download internet resources into the workspace; long webpages overflow to a workspace cache for continued reading (#221, #222)
- Compression mode enhancement: manual "keep recent N messages" compression, improving role-play / novel-writing sessions and reducing style drift (#236)
- Default compress/OCR prompt presets: more detailed built-in prompts with quick switching (#143)

### Fixed

- Markdown math rendering: multi-line formulas inside lists, plus `\tag` support (#227)
- Android update download: the in-app update now picks the APK matching the device ABI instead of always grabbing x86_64 (#230)
- LAN sync: proxy bypass, firewall auto-allow prompt, and mobile bottom-sheet fixes (#182)
- MCP UI simplification: advanced settings folded behind a disclosure (#224)

## [2.6.2] - 2026-08-07

### Fixed

- Temporary conversation: user messages can now be edited and resent (#215)
- Storage: iOS can now clear its temp file directory, and the system frees finished temp files more promptly (#223)
- Gemini API: parallel tool calls are now consolidated (#214)
- MCP OAuth: expired tokens are automatically refreshed (#225)
- Stability: uncaught errors are handled more gracefully — logged forcibly instead of crashing (#216)
- Rebranding: replaced the remaining icons, moved the QQ group to a dedicated one, and updated iOS usage instructions

## [2.6.1] - 2026-08-06

> v2.6.0 was a preview release; highlights include the new app icon, built-in filesystem MCP server, and Smart OCR mode decisions.

### Fixed

- Multi-assistant group chat: fixed a crash on Windows when navigating back from a group conversation (#206)
- Chat rendering: fixed a white screen on mobile when opening tool details while the AI is streaming (#208)
- Image sharing: fixed abnormal table background colors in exported images on iOS since v1.1.16 (#193)
- Backup restore: fixed skills failing to restore from backups and MCP servers being lost (#204, #207)
- Skills: completed the assistant-level quick entry on mobile (#201)
- Fixed several uncaught but non-crashing bugs (#191)

## [2.6.0] - 2026-08-04

### Added

- New app icon: switched to Cuplivo's custom artwork (commissioned by @Pheobe-Southwood)
- Built-in filesystem MCP server: read, write, and regex search, with local directory mounting — no command line, security-first (#173)
- OCR mode extension: new "Smart" OCR mode that keeps OCR off for vision-capable models and turns it on for those without vision (#171)
- Ta's letter (proactive care) decision mechanism: migrated from JSON output to more systematic tool calls

### Fixed

- Multi-assistant group chat: director logs are now displayed
- LAN sync: fixed a mobile-side UI issue and added a firewall hint

## [2.5.0] - 2026-08-03

### Added

- OAuth account sign-in: Grok xAI (#164) and OpenAI Codex (#157)
- MCP new standard support: OAuth v2.1 (#156)
- MCP image enhancement: send MCP tool result images back to LLM providers (#159)
- Rendering enhancement: reading mode for long assistant answers to reduce fatigue (#160)
- Skills enhancement: category mechanism, improved entry discoverability, optimized selection experience (#161)
- Logging enhancement: request logs now cover MCP, TTS, and search services (#162)

### Fixed

- Database intelligent self-healing: prevents permanent database version drift caused by a single failed migration or version anomaly

## [2.4.0] - 2026-08-01

### Added

- Multi-assistant group chat: a background director model decides which assistant speaks (#150)

## [2.3.0] - 2026-07-31

### Added

- Multi-key rotation for web search: configure multiple API keys to raise effective rate limits (#139)
- Handoff (subagent MCP): delegate subtasks to other assistants via an MCP tool; results are not returned yet (#140)
- LAN sync: device-to-device chat sync over local network with a two-round-trip protocol; 4-digit PIN authentication, reuses the incremental backup zip + merge restore infrastructure, syncs chats + referenced files + missing assistants (#136)
- Enhanced deletion: trash bin with configurable capacity (default 10 KB) to prevent accidental loss; sync carries local deletion markers so content deleted on one side is promptly removed on the other (#137)

## [2.2.1] - 2026-07-29

> **ℹ️ Windows users on v2.1.3–v2.2.0 please upgrade.**
>
> v2.1.3 introduced Win+V support via a Flutter workaround, but it was observed to cause the input box to become unresponsive after prolonged use. This version fixes the issue.

### Added

- Resolve MCP tool conflicts: auto-detect same-name tools, then choose to disable or add a prefix (#133)
- Storage space manager upgrade: sort by time/size, find unreferenced images/files, reverse-locate chat records (#128)
- Allow saving cloud-generated TTS audio locally (#131)
- Right-click / long-press selected assistant message text to speak it (#130)
- Beautify request logs: make message turns in the request body more readable (#127)

### Fixed

- One-click compression stat fix: correctly count and display the number of compressed images, and add proper text hints to the button (#129, #125)
- Fix input-box unresponsiveness caused by the Win+V change: pass through Flutter's probe to prevent keyboard mode regression (#135)

## [2.2.0] - 2026-07-26

### Added

- **Cache-friendly smart time injection**: injects the corresponding send time at each message (#121)
- **One-click image compression**: automatically compress images on send, no need to manually adjust each one (#119)
- **Preset messages enhancement**: preset messages can be collapsed; block new conversations when only preset messages exist (#116)
- **Provider-level custom Headers/Body**: each provider can attach custom request headers and body fields (#120)
- **Enhanced assistant message direct copy**: naive subsequence Markdown copy + quote (#122)
- Thinking toggles for summary/suggestion/compress/translate/OCR models (#117)

### Changed

- Refactor built-in Fetch MCP: merged into a single tool with enhanced token control (#115)

## [2.1.4] - 2026-07-25

### Added

- Batch select/delete/move conversations (#82)
- Custom theme color (#107)
- Configurable MCP heartbeat interval to avoid 429 rate limit (#108)
- Desktop markdown table toolbar with multi-format copy — image, TSV (for pasting into Excel), Markdown (#109)
- Configurable Grok reasoning effort for Web Search (#114)
- Model capability support: Sonnet/Opus 5, Gemini 3.6 Flash & 3.5 Flash Lite, Grok 4.5, Muse Spark 1.1 (#113)

### Fixed

- Restore legacy SSE compatibility for MCP servers (#110)
- Ensure Gemini tool call ID consistency (#111)
- Preserve provider reasoning effort/detail signatures across streaming (#112)

## [2.1.3] - 2026-07-25

### Added

- Skills v2: YAML-based skill definitions, async I/O, GitHub import, auxiliary file tools (#103)
- Render update release notes as markdown in side drawer (#106)

### Fixed

- Win+V clipboard history paste on Windows — workaround for Flutter engine bug (#105)
- Fix log viewer categorization on Windows — application logs tab was always empty due to backslash path separator handling (#100)

## [2.1.2] - 2026-07-22

### Added

- Toast notification when a response is truncated due to max_tokens or context window exceeded (#97)

### Fixed

- Stop button no longer requires two presses — `sub.cancel()` exception no longer leaves loading state stuck (#77)
- Translate stop button now actually closes the HTTP connection via CancelToken force-close (#96)
- Correct interleaved order of inline think blocks and tool calls across split boundaries (#95)
- Improved mobile background layout and iPad floating window support (#98)

## [2.1.1] - 2026-07-22

> ℹ️ **This release fixes a long-standing billing issue.** Since upstream Kelivo v1.1.6, clicking "Stop" never actually closed the underlying TCP connection. Providers were not notified of the cancellation, so even models supporting streaming cancellation could continue generating silently in the background — leading to unexpected token consumption and overcharges. **All users are recommended to upgrade.**

### Fixed

- Stop button now forcefully closes the underlying TCP connection, ensuring providers are immediately notified of cancellation and preventing silent background generation that caused overbilling (present since upstream Kelivo v1.1.6) (#79)
- Update about page GitHub links and update check URL to cuplivo/cuplivo (#80)

## [2.1.0] - 2026-07-21

> ⚠ **This release includes a critical backup-restore fix.** In versions 1.5.0–2.0.2, "Smart Merge" did not merge assistants from the backup file into the local database — now fixed to merge correctly.
> 
> v2.0 introduced **Android-specific Proactive Care** ("Ta 的来信"). Extra permissions may be requested; existing features are unaffected without granting them.
> 
> v2.1 introduces the **Skill** mechanism. This is a first cut — not fully featured yet; improvements will follow in subsequent releases.

### Added

- SKILLS mechanism — filesystem-based skill storage, import from file/manual entry, assistant binding, `load_skill` tool, backup support

### Fixed

- Smart Merge now correctly restores assistants from backup files (affects versions 1.5.0–2.0.2)
- Restore assistants to SQLite instead of SharedPreferences (prevents data loss) (#74)
- Multi-AI anchor system uses `groupId` instead of `messageId` for correct thread resolution (#72)
- Rename `userImagePaths` to `userMediaPaths`; fix office document handling in Responses API (#66)

## [2.0.2] - 2026-07-21

> ✅ **"Ta 的来信" (proactive care) is now fully functional in this release.**
> 
> **Proactive Care** lets AI assistatns send care messages to you on a configurable schedule **on Android only**. Extra permissions may be requested; for users who don't need this feature, just ignore them. **Existing features will not be affected without new permissions**.
> 
> Users on other platforms can still install this version as it introduces other fixes around the feature of MultiAI.

### Added

- Add model mid-conversation: a + button on the first-round card footer lets you insert a new model into an ongoing comparison (#68)

### Fixed

- Proactive care alarm not firing — `AlarmManager` is now initialised unconditionally, replacing the flawed permission-gated initialisation from v2.0.1 (#71)
- Multi-AI adopt now sets version selection for all rounds of the adopted thread, not just the first (#67)
- Badge editor: toggling off multi-select correctly returns to single model selection; badge tap opens editable selector at round 0
- Remove stale `version` parameter and redundant thread-resolution check

## [2.0.1] - 2026-07-20

> ❌ **This version is unusable.** The alarm-scheduling fix introduced in v2.0.1 was incomplete — proactive care alarms still never fire on most devices. Please upgrade to v2.0.2.

### Fixed

- Remove `USE_EXACT_ALARM` permission request, fixing the permission check that blocked "Ta 的来信" on Android
- Update default proactive care prompts

## [2.0.0] - 2026-07-20

> ❌ **This version is unusable.** The permission check logic for "Ta 的来信" (proactive care) is broken — the feature never works on any device. Please upgrade to v2.0.2.

### Added

- Proactive care (Ta的来信): AI sends care messages to users on a configurable schedule (#58)

## [1.9.1] - 2026-07-20

### Added

- Configurable focus-input hotkey (#60)

### Fixed

- Ensure assistant loaded before message generation to prevent system prompt race (#63)
- Gate input unfocus on resume to iOS only (#62)
- Markdown image regex stack overflow (definitive fix) (#61)

## [1.9.0] - 2026-07-19

> ⚠️ **Image generation users must update**
> 
> Since 1.4.1 switched image responses to base64 (`prefer b64_json`),
> the regex-based image-reference scanner hits catastrophic backtracking
> on large base64 payloads, causing a stack overflow on the second turn
> of any image-generation conversation. 1.9.0 replaces the regex with
> linear indexOf scanning.

### Added

- PDF/Office file attachments: upload PDF, Word, Excel, and PowerPoint documents directly, with document processing configuration (#26)

### Fixed

- Multi-AI retry matrix: context truncation, version selection timing, and guard toasts (#54)
- MCP: skip heartbeat reconnect on rate-limit errors (429 / -32106) (#53)
- Large base64 images no longer cause regex stack overflow — replaced with indexOf scanning (#55)

## [1.8.0] - 2026-07-19

### Added

- Multi-AI synthesize mode: after comparing model responses, fork the conversation and let an AI summarize, fuse, or comment on all outputs — like a more flexible OpenRouter Fusion (#52)

## [1.7.2] - 2026-07-19

> ⚠️ **SVG preview users on 1.7.0–1.7.1 must update**
> 
> Previous releases crash when LLM streams SVG code blocks: flutter_svg's
> isolate parser spawns repeated `compute(encodeSvg)` on partial / invalid
> XML chunks during streaming output, causing an isolate storm. 1.7.2 adds
> streaming debounce (360 ms alive / 220 ms settled), auto-switches to Code
> tab during streaming, enforces a 1 MB size limit, and adds an error
> fallback. SVG preview users should upgrade immediately to avoid random
> app kills.

### Added

- Desktop comparison view now shows 2 model columns per page instead of
  single-card swiping (#50)

### Fixed

- SVG preview isolate storm crash during LLM streaming (#46)
- Thread anchor lost on `dropThread` causing auto-adopt failure (#51)

## [1.7.1] - 2026-07-17

> ⚠️ **Mobile users on 1.7.0 must update**
> 
> 1.7.0 shipped with a critical multi-select UX regression on mobile:
> the model picker auto-entered multi-select mode on every open, making
> normal model switching nearly impossible. This release restores the
> intended behavior and adds missing multi-select visual feedback.

### Added

- Kimi K3 model support with max reasoning and both naming variants (#43)

### Fixed

- Multi-AI mode: mobile no longer auto-enters multi-select on model open;
  model tiles now show checkboxes and highlight during multi-select;
  active model pre-selected on entering multi-select;
  clicking current conversation no longer exits multi-AI (#41)
- reasoning tags now stripped from auto-generated conversation titles (#42)

## [1.7.0] - 2026-07-17

### Added

- Multi-AI side-by-side comparison mode (#16)

## [1.6.1] - 2026-07-14

### Added

- GPT-5.6 model family support (sol/luna/terra) with low/medium/high/xhigh/max reasoning effort

### Fixed

- Tool schema sanitization now preserves `additionalProperties` for OpenAI and Claude function/tool definitions

## [1.6.0] - 2026-07-13

> 💡 **What's new**
> 
> This release introduces the **Memory Mode Switcher** — a per-assistant toggle that
> lets you choose between **Auto Injection** (memories always injected into the system
> prompt) and **On Demand (Tool)** (memories accessed via the `read_memory` tool only
> when needed). Tool mode keeps the system prompt stable, significantly improving API
> cache hit rates and reducing latency.

### Added

- Memory mode switcher — per-assistant toggle between Auto Injection and On Demand (Tool) mode
- `read_memory` tool for on-demand memory retrieval in Tool mode

### Changed

- Memory system now supports on-demand (Tool) mode: instead of always injecting all
  memories into the system prompt, assistants can read memories via tools only when
  needed. This keeps the system prompt stable, dramatically improving API cache hit rates
- Extracted `_cleanupStreamingError` utility; fixed copy-paste log tag error

## [1.5.0] - 2026-07-13

> ⚠️ **Before Upgrading**
> 
> This release migrates assistant storage from SharedPreferences to SQLite.
> **Please back up your chat history via Settings before upgrading** to guard
> against any edge-case data anomalies.
> 
> It also fixes a critical issue where old conversations could not be resumed
> after restart due to immutable `messageIds` lists. If you encountered this,
> the upgrade will restore normal functionality.

### Added

- Server tool events — OpenAI server-executed tool calls rendered as native tool cards

### Changed

- Assistant storage migrated from SharedPreferences to SQLite, improving reliability and extensibility

### Fixed

- Old conversations could not send messages after restart due to immutable `messageIds` (#22)
- Past OCR results were lost after app restart (now persisted to SQLite via `CacheRows` table)
- `fetch_markdown` tool output did not strip `<script>` and `<style>` tags (#17)

## [1.4.1] - 2026-07-12

### Added

- SVG code block preview — render SVG diagrams inline within svg code fences

### Fixed

- Prefer `b64_json` key for OpenAI image response parsing

### Changed

- Tool descriptions rewritten for conciseness and accuracy (tool prompt optimization)
- Shared PreviewLoadingView and PreviewErrorView components

## [1.4.0] - 2026-07-06

### Added

- Image compression: interactive compression with size overlay and quality dialog
- Memory: record prompt editor in Memory tab

### Changed

- Backup: refactored shared code extraction (formatBytes, RestartRequiredDialog, etc.)

### Fixed

- Backup: import error feedback with try/catch wrapping
- Backup: conservative file inclusion on stat error

## [1.3.0] - 2026-07-05

### 🚀 Features

- Incremental backup with message-level filtering and scope preview
- Incremental attachment export with mtime filtering
- Persist includeSettings and updateBackupTime toggles across sessions

### 🐛 Fixes

- Fix multiple bugs across importers, models, API streaming, and desktop UI
- Chatbox/cherry importer regex and path escaping on Windows
- S3 client error response variable reference
- ChatMessage groupId defaulting to null instead of generated id
- Conversation fromJson crash on missing messageIds key
- Settings avatar path double-backslash check on Windows
- Emoji picker TextEditingController leak
- Assistant settings edit page null guard in desktop dialog
- Claude/OAI unsafe `as` casts causing silent chunk loss in streaming

### ⚡ Performance

- Batch insert restore data in single transaction

## [1.2.0] - 2026-07-02

### 🚀 Features

- Migrate chat history storage from Hive to SQLite
- Add image warning pill when draft images exceed model capability
- Add emoji preset for title prompt with hash fingerprint matching
- Update storage usage tracking to account for SQLite database files
- Improve migration UI with _Saving backup ZIP_ status and schema stage
- Update migration UI and localization text

### 🐛 Fixes

- Read `cachedContentTokenCount` from Gemini `usageMetadata` for Vertex AI
- Broaden Qwen 3.5-3.7 and Doubao seed-2 model capability detection
- Retry triggers title generation after first conversation failure

### ♻️ Refactors

- Unify duplicate tabbed-preview UI into shared components
- Use seconds-based timestamps for SQLite DateTime conversion

### ⚡ Performance

- Optimize Hive to SQLite migration with batch inserts

### 🔧 Chores

- Fork to Cuplivo — rebrand package to `com.cup11.cuplivo`
- Rename package from Kelivo to Cuplivo, bump to 0.1.0
- Remove Hive and migration code
- Bump `reel_text` to 0.4.0
- Remove stale workflows, update build-stable-44 target name
