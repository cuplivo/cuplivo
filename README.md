<div align="center">
  <img src="assets/app_icon.png" alt="Cuplivo Icon" width="100" />
  <h1>Why Cuplivo?</h1>

  A Flutter LLM Chat Client — A community fork
  
  Cuplivo official QQ group: `1101061750`

  [阅读简体中文文档](README_ZH_CN.md)快速查看特性
</div>

## 🔗 Compatibility

Cuplivo is a community fork of Kelivo with strong compatibility focus:

- **Backup zip format fully compatible.** Configure WebDAV or S3 (or local export/import), restore backup files exported from Kelivo, and pick up where you left off — no reconfiguration needed.
- **Package name changed to avoid conflicts.** Many developers worry that their custom changes will conflict with future Kelivo updates; but installing Cuplivo **does not require uninstalling and will not overwrite** Kelivo — your data is doubly protected.
- **Verified by real users.** Currently known to be used by the author and at least 5 other stable users with no issues reported.
- **UI inherits Kelivo's style.** No major changes overall; existing users will feel right at home.

### 🧪 Stability

This fork is positioned as a **"new feature proving ground"**: it may adopt features the community finds useful, most verified through lightweight self-testing, aiming to provide a more out-of-the-box experience for users seeking the latest capabilities. Basic availability and stability are maintained (no P0 bugs; no data corruption or crash-on-launch bugs encountered so far), but releases are more frequent with lighter review. New features may carry P1/P2-level bugs, though feedback will be addressed promptly.

We are aware that the upstream Kelivo repository is undergoing a major data storage refactoring. In the near term, this fork plans only to maintain compatibility with the new-format `.zip` exports from upstream. Most defensive data-integrity changes made here may not be adopted upstream — **please keep your own backups.**

## ✨ New Features

Unlike most personal-customization or single-feature forks, Cuplivo aims to add multiple features for a broader audience to try out. Some items may be removed as upstream (Kelivo) adds their counterparts.

### Backup & Sync Enhancements

1. **Incremental backup & LAN sync** — Uploads only conversations, messages and related attachments since a selected date; quickly sync two devices' state over LAN.
   - *In practice*: A 12.6 MB full backup is typically followed by incremental uploads of 50 KB to 1.5 MB. Savings become more apparent as attachments and images accumulate. This reduces bandwidth and storage overhead, encouraging more frequent backups.
   - *Note*: Periodic full snapshots are still recommended.

2. **Deletion recovery (trash bin)** — Deleted conversations go to a trash bin with configurable capacity (default 10 KB) to prevent accidental loss; sync carries deletion markers so content removed on one side is promptly purged on the other (#137).

3. **Import from RikkaHub** — Convert a RikkaHub backup into a Cuplivo-compatible backup through the migration website, then import it via "Import Backup File" (#165).

### Signature Chat Experience

1. **Proactive care** — AI can proactively send care messages to users on a configurable schedule (Android only).
   - *Android-only*: background alarm + notification channel; alarm persists through force-stop

2. **Multi-assistant group chat** — Director-orchestrated group conversations: a background director model decides which assistant speaks, and each member chats in a shared thread with private context (#150).

3. **Built-in filesystem MCP server** — Read, write, and regex-search local files through an in-memory MCP server; mount local directories without a command line, security-first. Browse mounted directories in an in-app file browser, with paginated grep results and context, code structure outlines (`kelivo_outline`), downloading internet resources into the workspace, and long-webpage workspace cache continuation (#173, #221, #222).

4. **Multi-AI side-by-side comparison** — Select 2 or more models to answer simultaneously and compare their responses side by side — pick the best result, or synthesize them into a single reply via summary, fusion, or commentary (like a more flexible OpenRouter Fusion).
   - Desktop now shows 2 model responses per page in a two-column layout.
   - *Tip*: Multi-select models in the model picker before sending a message to activate this mode.

5. **Memory mode switcher + Time injection** — Per-assistant toggles that keep the system prompt stable for better API cache hits: switch memories between **Auto Injection** (injected into system prompt on every turn) and **On Demand (Tool)** (accessed via `read_memory` tool only when needed); optionally append a cache-friendly timestamp after each user message instead of baking time into the system prompt. A smart warning dialog scans the system prompt and memory record prompt for volatile variables when time injection is enabled (#121).
   - *Tip*: For best cache performance, disable Recent Chats Reference, switch to On Demand mode, and enable time injection.

### Agent Capabilities

1. **Handoff (subagent delegation)** — Delegate subtasks to other assistants via an MCP tool (fire-and-forget). True result-returning subagents are planned for a future release (#140).

2. **Skills** — Import skills from public GitHub repositories, plus auxiliary file tools for skill execution. Skills are persisted on the filesystem and included in backups. v3 adds categories, a master toggle, and chat-level skill entry (#161).

### API & Provider Control

1. **OAuth account sign-in** — Device-code sign-in for Grok xAI (#164) and OpenAI Codex (#157); MCP OAuth v2 auto flow with authorization server discovery, dynamic client registration, and loopback callback (#156).

2. **Multi-key rotation for web search** — Configure multiple API keys for the search service; keys rotate automatically on rate limit to raise effective quotas (#139).

3. **MCP tool result images** — Send images returned by MCP tools back to LLM providers so models can see tool outputs (#159).

4. **Provider-level custom Headers/Body** — Attach custom headers and body fields per provider (#120).

5. **Per-assistant OCR mode** — New "Smart" OCR mode: OCR stays off for vision-capable models and turns on for those without vision; per-assistant auto/always/never control (#171).

6. **Per-server heartbeat interval** — Configure heartbeat interval per MCP server to avoid 429 rate limits (#108).

7. **PDF/Office file attachments** — Upload PDF, Word, Excel, and PowerPoint documents directly as attachments, with configurable document processing options.

8. **Thinking toggles** — Per-assistant thinking toggles for summary/suggestion/compress/translate/OCR models (#117).

### Practical Utilities

1. **Manual keep-recent compression + prompt presets** — Compress a conversation keeping the most recent N messages, with a live token-estimate preview (default keep-count scales with conversation size), improving role-play / novel-writing sessions and reducing style drift; quick-switch between built-in compress/OCR prompt presets (#143, #236).

2. **Batch select/delete/move for conversations** — Select, delete, or move multiple conversations at once in the sidebar for efficient conversation management (#82).

3. **Storage space manager** — Sort stored files by time or size, find unreferenced images/files (orphans), and reverse-locate which chat record a stored file belongs to (#128).

4. **TTS audio: save locally + speak selection** — Save cloud-generated TTS audio to a local file from the floating player (#131); right-click / long-press selected assistant message text to speak it (#130).

5. **Enhanced assistant message direct copy** — Naive subsequence Markdown copy + quote for quick message extraction (#122).

6. **Multi-category request logging** — Request logs now cover MCP, TTS, and search services, each in its own category with independent toggles and history (#162).

### UI & Rendering

1. **Reading mode** — Long assistant answers can open in a dedicated reading mode to reduce fatigue (#160).

2. **SVG preview** — Renders SVG diagrams inline within `svg` code blocks.

3. **Custom dynamic color (seed)** — Pick a custom seed color for the dynamic color scheme, giving you full control over the app's accent color with a hue picker (#107).

4. **Beautify request logs** — Split messages from config in the log viewer so message turns in the request body are easier to read (#127).

5. **Desktop markdown table toolbar** — Format and copy markdown tables with a dedicated desktop toolbar supporting multi-format copy (plain text, HTML, LaTeX) (#109).

6. **Preset messages** — Preset messages collapsed behind a toggle bar in the chat list; new conversations are blocked when only presets exist (#116).

### Additional Fixes

- **Force-close TCP on stop** — The long-standing issue since upstream Kelivo v1.1.6 is now fixed: clicking "Stop" never actually closed the TCP connection. Providers were not notified of cancellation, causing silent background generation and unexpected token consumption / overbilling
- **Cross-MCP same-name tool conflicts** — Fixed: when multiple MCP servers expose tools with the same name, the collision is now detected and resolved (disable or rename) instead of causing ambiguous tool calls
- Accurate Gemini cached-token reporting
- Optimized title generation logic (auto-retry on first failure)
- Large base64 images no longer cause regex stack overflow
- Markdown math formulas now render correctly: multi-line formulas inside lists, plus `\tag` support (#227)
- Win+V clipboard history paste fix for Flutter engine bug on Windows
- iOS: exported chat images now use 8-bit sRGB readback, fixing abnormal table background colors since v1.1.16 (#193)
- iOS: storage space manager now counts and clears the real iOS tmp directory (#223)
- Various other stability improvements

## ⚠️ Note

Cuplivo is a community fork and has not been fully separated from the upstream project. The QQ group now belongs to Cuplivo (group `1101061750`); donation QR codes and Discord still point to the original author. Some references may retain the original name during the transition. The app icon has been replaced with Cuplivo's custom artwork (commissioned by @Pheobe-Southwood).

---

<div align="center">
  <img src="docx/screenshot_1.png" alt="Chat Screen" width="150" />
  <img src="docx/screenshot_2.png" alt="Model Selection" width="150" />
  <img src="docx/screenshot_3.png" alt="Tool Calling" width="150" />
  <img src="docx/screenshot_4.png" alt="Web Search" width="150" />
</div>

## 🚀 Download

🔗 [Download the latest version](https://github.com/Chevey339/kelivo/releases/latest)

> **iOS:** Cuplivo is not on the App Store. Please install it by self-signing (e.g. Sideloadly, AltStore, or other signing tools).

## 💖 Sponsors

Thanks to [siliconflow.cn](https://siliconflow.cn) for providing free models in cooperation with us.

## ✨ Features

- 🎨 **Modern Design** - Material You design language with dynamic color theming support (Android 12+).
- 🌙 **Dark Mode** - Perfectly adapted dark theme to protect your eyes.
- 🌍 **Multi-language Support** - Supports both English and Chinese interfaces.
- 🖥️ **Multi-platform Support** - Mobile (Android/iOS/Harmony) and Desktop (Windows/macOS/Linux).
- 🔄 **Multi-provider Support** - Supports major AI providers like OpenAI, Google Gemini, Anthropic, etc.
- 🤖 **Custom Assistants** - Create and manage personalized AI assistants.
- 🖼️ **Multimodal Input** - Supports various formats including images, text documents, PDFs, Word documents, etc.
- 📝 **Markdown Rendering** - Full support for code highlighting, LaTeX formulas, tables, and more.
- 🎙️ **Voice/TTS Providers** - Built-in system TTS plus OpenAI / Google Gemini / ElevenLabs voice servers.
- 🛠️ **MCP Support** - Model Context Protocol tool integration.
- 🧰 **Built-in MCP Tools** - Includes a built-in MCP Fetch tool.
- 🔍 **Web Search** - Integrated with multiple search engines (Bing, DuckDuckGo, Exa, Tavily, Zhipu, LinkUp, Brave, Metaso, SearXNG, Ollama, Jina, Perplexity, Bocha, Serper, Grok).
- 🧩 **Prompt Variables** - Supports dynamic variables like model name, time, etc.
- 📤 **QR Code Sharing** - Export and import provider configurations via QR codes.
- 💾 **Data Backup** - Supports chat history backup and restoration.
- 🌐 **Custom Requests** - Supports custom HTTP request headers and bodies.
- 🔡 **Custom Fonts** - Bring your own fonts (system fonts / Google Fonts).
- ⚙️ **Android Background Generation** - Keep chat generation running in the background (optional setting).

## 📱 Platform Support

- ✅ Android
- ✅ iOS
- ✅ Harmony ([kelivo-ohos](https://github.com/Chevey339/kelivo-ohos))
- ✅ Windows
- ✅ macOS
- ✅ Linux

## 🤝 Contribution Guide

Pull Requests and Issues are welcome!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## ❤️ Acknowledgements

Special thanks to the [RikkaHub](https://github.com/re-ovo/rikkahub) project for the UI design inspiration. Kelivo's interface design is heavily inspired by RikkaHub's beautiful and practical design.

Special thanks to [OpenCode](https://opencode.ai) — the design of our file system tools is heavily inspired by OpenCode.

## ⭐ Star History

If you like this project, please give it a star ⭐

[![Star History Chart](https://api.star-history.com/svg?repos=Chevey339/kelivo&type=Date)](https://star-history.com/#Chevey339/kelivo&Date)

## 📄 License

This project is licensed under the AGPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## 📞 Contact Us

- Issue: [GitHub Issues](https://github.com/Chevey339/kelivo/issues)

---

<div align="center">
Made with ❤️ using Flutter
</div>
