# Changelog

## [3.1.1] - 2026-08-30

### Added

- **Backup page redesign**: the backup page has been redesigned with a shortcut entry added on the home page for a smoother experience (#306 by @cup113)
- **Conversation export to PDF**: export conversations to PDF — limited to Windows + WebView mode (#293 by @cup113)
- **Message multi-select & share merged**: conversation message multi-select and share are unified into a single entry (#561 by @cup113)
- **Import restore progress modal**: backup imports are locked behind a modal with live restore progress, preventing accidental operations and blind waiting (#583 by @cup113)
- **World book discovery**: expanding the input bar shows world books grouped, and active assistants can be bound quickly when creating/editing entries (#501 by @cup113)
- **Hide built-in providers**: built-in providers can be hidden (#295 by @cup113)

### Fixed

- **WebView font rendering**: fixed the Web conversation view not using the selected app/code fonts (#600 by @cup113)
- **WebView mobile scrolling & iOS compatibility**: mobile touch panning is handed back to the WebView; iOS now serves the shell from a loopback HTTP origin, fixing WebView failure to open (#619, #617 by @cup113)
- **Desktop panel width persistence**: side panel widths are restored on restart (#594 by @cup113)
- **Chat background bounce with keyboard**: the chat background stays still when the keyboard opens (#297 by @cup113, @Chevey339)
- SSRF guard now passes through fake-IP DNS answers, no longer blocking legitimate domains (#547 by @HowieATP, @cup113)
- Context management entry became dead after folding into "+" — the button now works again (#603 by @cup113)
- Preset messages: fixed infinite preset creation; preset-only conversations are recycled on leave and the send queue is scoped per conversation (#592 by @cup113)

## [3.1.0] - 2026-08-28

### Added

- **Experimental Web conversation view**: with the experimental toggle enabled, regular conversations on Android/iOS/macOS/Windows can switch to WebView rendering, supporting import of declarative "Web conversation style library" JSON styles, including bubble styling once enabled (#555 by @Pheobe-Southwood)
- **Backup v2 (JSONL + LWW)**: the backup format is upgraded to streaming JSONL writes, lowering peak memory for large backup restore and export, while keeping the Kelivo-compatible export path (#560 by @cup113)
- **Backup export experience**: export stages now show progress and elapsed time, avoiding blind re-taps; fixes silent export failures (#549 by @cup113)
- **Message reply**: added a QQ-style reply feature (via long-press text selection or the message-level "More" button), with smart quote display and context trimming (#559 by @cup113)
- **Assistant & conversation-level working directories**: assistants and conversations can keep independent working directories per workspace, and automatically load `AGENTS.md` into the system prompt (#495 by @Pheobe-Southwood)
- **Customizable input bar buttons**: input bar buttons can be reordered and shown directly or tucked into "More" (#532 by @cup113)
- **Local device tools**: ported upstream screen time and calendar local tools (screen time is Android-only; calendar supports Android/iOS, with optional reminders for `calendar_create`) (#534 by @cup113, @Chevey339)
- Workspace dependency expansion: new detection for GitHub CLI, curl, OpenSSH Client, zip/unzip, compile toolchains, plus dependency prerequisites
- Keep message versions when forking: new "Keep message versions when forking" switch, off by default (#548 by @cup113, @Chevey339)
- Smart time injection compatibility: synced upstream time injection UI — append current time row, volatile-variable ⚠ badges, and format info (#541 by @cup113, @Chevey339)
- Import from new Kelivo: backup page gains an import entry and guide for newer Kelivo versions (#566 by @Pheobe-Southwood)
- Opt-out for screen awake during generation: mobile screen-awake during generation can now be disabled (#568 by @cup113)

### Changed

- **Business preferences migrated to SQLite**: business preferences now live in a SQLite KV table instead of SharedPreferences, making persistence more reliable (#560 by @cup113, @Chevey339)
- **Subagent UX upgrade**: unified terminology to "delegate to subagent", improved setup guidance, and retired the rarely-useful non-waiting delegation to avoid user/AI confusion (#542 by @cup113)
- **MCP connection synced with upstream**: safe session reuse, heartbeat mechanism retired (#558 by @cup113, @Chevey339)
- Search service copy: Fetch functionality is now uniformly phrased as "Browse" (#563 by @Pheobe-Southwood)

### Fixed

- **Android SAF mount sync**: fixed zero-file copies caused by `path_provider` directory layout not matching the native path allowlist (#529 by @HowieATP, @cup113)
- **Markdown code block rendering**: unified the code scanning engine, correctly rendering text like `D:\` instead of treating it as escaped (#561 by @cup113)
- Tools Hub: the Tools Hub button no longer requires an MCP server, improving discoverability of local tools and terminal; row pitch tightened for a more compact UI (#550 by @cup113)
- Workspace dependency detection: failures no longer overwrite previous successful results (#567 by @Pheobe-Southwood)
- Fixed post-send chat "bounce": ported upstream `super-silver-list` to prevent mis-framed scroll (#530 by @cup113, @Chevey339)
- iOS Live Activities: orphaned activity cards are cleaned up on launch and before creating a new one (#536 by @HowieATP); fixed ActivityKit build compatibility (#564 by @Pheobe-Southwood)
- Math formula export: keeps display-math source intact; wide formulas scale down to fit the export canvas (#539 by @HowieATP)
- Sandbox runtime: fixed iOS Node termination without fetch, removed fixed exit waits and polling, Android tar buffer reuse (#562 by @Pheobe-Southwood)
- iOS sandbox pipes: transferred pipe read-end ownership to fix fd races (#535 by @HowieATP)

## [3.0.3] - 2026-08-22

### Added

- **Android SAF external-directory mounts**: mount Android external directories into the workspace via SAF with scheduled syncing (#316 by @cup113, @Pheobe-Southwood)
- **Search services sync**: synced upstream search services (new providers, account usage) (#510, #511 by @cup113, @Chevey339)
- **Custom themes**: ported upstream custom theme system (#516, #300 by @cup113, @Chevey339)
- **Markdown performance**: ported upstream incremental streaming Markdown block renderer for smoother live rendering of long answers (#334 by @cup113, @Chevey339, @banana4432, #527 by @Pheobe-Southwood)
- New model support: deepseek-v4-flash-vision, Qwen3.8 series, muse spark series, grok-4.6, gemini-3.7-flash, dots3-note (#513 by @cup113, #524 by @cup113, @VictorSun92)
- Pin a startup assistant: a chosen assistant is auto-selected when the app restarts (#517 by @cup113)
- Keep screen on while generating: mobile keeps the screen on during AI generation (#520 by @cup113)
- GLM-OCR support: official GLM-OCR service and empty prompts (#519 by @cup113, @Chevey339)
- Manual database compaction: one-click compact the SQLite database to reclaim freelist holes (#508 by @cup113)
- Live panel visual unification: live entries unified inside the input bar card with a unified rounded-border style (#523 by @cup113, @getpaseo)

### Fixed

- **LAN sync**: added restore progress display; no longer uploads unnecessary files; blocked sync sessions are closed, fixing long-duration syncs and weak signals (#509, #515 by @cup113)
- **Gemini compatibility**: stripped `additionalProperties` from tool schemas, fixing tool call failures (#425 by @cup113)
- Android 32-bit ARM sandbox: sandbox runtime now supports 32-bit ARM devices (#496 by @Pheobe-Southwood)
- iOS sandbox: uses the system DNS to prevent network unavailability; rootfs is installed atomically to prevent mid-install corruption; fixed sandbox commands escaping the working directory (#463 by @cup113, #471 by @HowieATP, #456 by @HowieATP)
- World-book keywords: the input keeps focus after adding a keyword, so the keyboard stays open for quick additions (#514 by @cup113, @xuanxuan9929)
- Storage scan: tolerates unreadable subdirectories, no longer interrupting usage scans (#525 by @cup113)
- Backup merge: restore merge no longer syncs proxy settings (#512 by @cup113)

## [3.0.2] - 2026-08-18

### Added

- **Tools Hub**: MCP servers, local tools, and workspace management (including mounts and Android terminal launch) unified into the original MCP entry, for quick adjustments during chat (#491 by @cup113)
- **iOS background keep-alive**: ported OpenMinis' advanced background keep-alive to iOS, so proactive care and background tasks can run on iOS (#434 by @banana4432, @OpenMinis)
- **Translucent Markdown blocks**: code, table, and `<details>` blocks now use translucent backgrounds, improving the look over chat background images (#452 by @cup113)
- **Batch pin/unpin**: pin or unpin multiple conversations at once from conversation select mode (#487 by @cup113)

### Fixed

- **Memory race**: memory edits are now serialized to prevent duplicate IDs from parallel `create_memory` calls and similar issues (#479 by @xuanxuan9929, @cup113)
- **Backup compatibility**: `chats.json` is exported as version 1, so Cuplivo backups can be imported back into Kelivo (#453 by @banana4432)
- **Backup & sync**: importing Kelivo v1.2.x backup files now guides users to the website to downgrade instead of silently overwriting and losing data; backups restore reliably when importing files; LAN sync now covers settings (#480 by @cup113)
- **Storage space manager**: new usage categories (workspace/skills/fonts/sandbox) so the size distribution displays completely; new sandbox cleanup; statistics now use streaming scanning to avoid freezes (#451 by @cup113)
- Edited message versions now keep their original timestamp (#488 by @cup113, @xuanxuan9929)
- Storage cleanup: iOS automatically cleans up clipboard paste temp files and honors the Dart-provided file name on save (#469 by @HowieATP)
- Google API: non-string enum values are filtered out so tool calls no longer fail for models like Gemini 3.5 Flash Lite (#489 by @cup113, @rikkahub)
- Ta's message: world-book time is now injected into the context, grounding the AI in the current in-world time (#494 by @Pheobe-Southwood)
- Log analysis: a filename marker with a token budget prevents token explosion during log analysis (#435 by @banana4432)
- Workspace files: on mobile, HTML files render in the built-in WebView and images render in-app, avoiding system viewers that lack format support (#492 by @cup113)
- Math formula PNG export: transparent background; mobile now saves the PNG to the gallery (#490 by @cup113)
- Reminder improvements: backup reminder now uses a one-shot timer instead of 1-minute polling; update checks respect the disabled setting (#375 by @HowieATP, @cup113, @Chevey339)
- Sandbox: Android rootfs extraction skips `./` root-dir entries instead of failing (#472 by @HowieATP)
- Sandbox: shell output truncation no longer splits UTF-16 surrogate pairs (#468 by @HowieATP, @cup113)
- Mini-map and global search strip `<thinking>` tags, matching message rendering (#455 by @HowieATP)
- Chinese locales: remaining "skills" strings localized to 技能 (#482 by @banana4432, @cup113)

## [3.0.1] - 2026-08-15

> ℹ️ v3.0.1 is the first stable release of the v3 line. v3 mainly introduced the sandbox and speech recognition, improved multi-workspace, and retired the built-in fetch, filesystem, and subagent MCP servers — this may be a breaking change. See [https://github.com/cuplivo/cuplivo/releases/tag/v3.0.0](https://github.com/cuplivo/cuplivo/releases/tag/v3.0.0) for details.

### Added

- **Android interactive terminal**: a Termux-like terminal can be opened on Android, independent of the Shell tool; no keep-alive yet, no persistence across restarts (#428 by @Pheobe-Southwood)
- Image-mode refactor: image-generation options moved into a collapsible live panel, with quick switching from chat mode to image mode and usage notes (#438 by @cup113)
- AI log analysis: let AI analyze redacted logs right from the request log UI (#390 by @banana4432)
- Tool API: OpenRouter image generation tool compatibility (#346 by @cup113, @Chevey339)
- Skills: collapsible groups (#426 by @xuanxuan9929, @cup113)
- Rendering: compatible with `<thinking></thinking>` reasoning tags (#354 by @cup113, @Chevey339)

### Changed

- Multi-assistant group chats merged into the assistant list to reduce entry clutter (#403 by @banana4432)
- Disabled .so compression for faster cold start and lower post-install storage (#353 by @Pheobe-Southwood)
- Updated the reasoning content replay mechanism (#351 by @cup113, @Chevey339)
- Sandbox commands now inject GOMAXPROCS/GODEBUG to lower Go runtime overhead under emulation (#376 by @xuanxuan9929)

### Fixed

- Fixed **iOS** background tasks not starting due to an identifier naming mismatch (#382 by @HowieATP)
- Fixed **shell** tool calls causing **crashes/freezes** (#431 by @Pheobe-Southwood, #383 by @HowieATP)
- Fixed an Android sandbox dependency-install race that could corrupt the filesystem (#408 by @Pheobe-Southwood)
- Fixed proactive care "Ta's message" not triggering when the foreground countdown elapsed (#424 by @Pheobe-Southwood)
- Fixed sandbox dependencies being invisible (#427 by @Pheobe-Southwood)
- Fixed DeepSeek Responses API reasoning and cache-hit anomalies (#368 by @cup113, @Chevey339)

## [3.0.0] - 2026-08-13

> ⚠️ Major release — features may be unstable. Replacing built-in MCP with local tools is a breaking change: historical task context may be polluted, but newly-created conversations are unaffected.

### Added

- Linux sandbox support: **Android** can select a distribution in-app, **iOS** runs the sandbox via iSH; users who complete the setup **can execute command-line tools** (#301)
- Built-in multi-workspace: on all platforms, simple file read/write without downloading a Linux kernel; the built-in workspace does not support command-line execution (#301)
- Speech recognition (ASR): ported from upstream, selectable ASR services with per-assistant configuration (#330)
- Text-to-speech (TTS) expansion: synced upstream TTS providers Qwen Audio / StepFun / Fish Audio (#332, #337)
- Skills built-in tools: the assistant can now call tools to import and create Skills (#319)
- Skills panel revamp: improved UI mimicking the MCP style; removed the "+" button in the bottom-right of the management interface to avoid blocking (#313, #344)
- Math formula export: **block-level formulas** can be copied as LaTeX / copied as PNG / downloaded as PNG (#345)
- Batch export conversations: export multiple conversations to Markdown in one go (#276, #305)
- Live panel expansion: the live panel now shows download progress and unifies the image-generation mode and ignore-image-warning design style (#347)

### Changed

- Windows rounded app icon (#327)
- Rebranding completed: remaining Kelivo user-visible/outbound identity replaced with Cuplivo; removed the Discord link and the KelivoIN built-in provider (#286)
- Refactored conversation generation: general chat, multi-assistant group chat, multi-AI comparison, and subagents now flow through a single engine, eliminating incomplete duplicate implementations (#287)

### Removed

- Retired the built-in fetch, filesystem, and subagent MCP servers: replaced by the workspace local tools above (#301)

### Fixed

- Switching conversations mid-chat no longer resets the thinking card's timer to zero and auto-collapses it (#287)

## [2.7.1] - 2026-08-11

> ℹ️ If you've been experiencing crashes on Windows, please upgrade: this release fully fixes the crash that occurred after maximizing the window, closing dialogs, or navigating between pages, introduced in v2.2.0.

### Added

- Message-level search: search within a conversation's mini-map, filter to matching messages, and highlight the matches (#270)
- Image-compression backup sync: bidirectional import/export of the new Kelivo image-compression settings (#124)
- Test connection improvements: the current model is now auto-selected (#280)

### Fixed

- Windows crash fix: replaced the built-in slider with Syncfusion (SfSliderTile) to fix crashes caused by a corrupted accessibility tree (#281, fixes the regression introduced by #119, a Flutter compatibility issue)
- MiniMax TTS emotion parameter support: clearing the "emotion" input lets the AI decide the emotion from content (auto mode) (#284)

## [2.7.0] - 2026-08-10

> ℹ️ Android users please note: the in-app auto-update previously always downloaded the x86_64 build; this was fixed in 2.6.3, but if you are still on a version older than 2.6.3, you still need to grab the arm64-v8a APK from the GitHub Release page.

### Added

- Full subagent experience: new wait mode lets a subagent return its result to the main agent for further processing, with a live progress panel in the parent conversation; parallel calls supported (#251)
- Workspace enhancements: the built-in workspace directory is now user-configurable on desktop; added "open externally" and share buttons; improved file preview line numbers; fixed empty-folder display (#250)
- HTML rendering enhancement: HTML code blocks now render inline in the chat list — just have the assistant output an HTML code block — enhancing role-play and other chat experiences (#203)
- Input drafts: your typed input is saved as a draft and restored when the app restarts, recovering your last unsent content (#246)
- Image generation options panel: visual configuration for OpenAI Images API models — quickly control quality, size/aspect ratio, output format, count, and more (#248)
- Default behavior changes: DeepSeek provider enabled by default; assistant temperature / top_p and similar parameters disabled by default; request logging on by default with a 50 MB cap; users with existing configurations are unaffected (#240)
- Slightly smaller install package size (#241)

### Fixed

- Long-message streaming performance: smart throttling added for rendering and database writes (#232)
- Multi-assistant group chat: assistants are now aware of the members in a group chat; fixed the settings UI; group avatars can now be set (#219)
- Kaomoji rendering: bundled a fallback font for rare characters so kaomoji are no longer rendered incorrectly (#249)
- Token statistics: assistant messages with multi-round tool calls now count their tokens as a sum — in-app statistics no longer undercount token consumption (#247)

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
