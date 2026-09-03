<div align="center">
  <img src="assets/app_icon.png" alt="Cuplivo Icon" width="100" />
  <h1>Why Cuplivo?</h1>

  A Flutter LLM Chat Client — A community fork
  
  Cuplivo official QQ group: `1101061750`

  [阅读简体中文文档](README_ZH_CN.md)快速查看特性
</div>

## 🔗 Compatibility

Cuplivo is a community fork of Kelivo with strong compatibility focus:

- **Backup zip format compatible.** Export locally in Kelivo, then restore the backup file in Cuplivo and pick up where you left off — no reconfiguration needed.
  - *Note*: Kelivo v1.2.x underwent a large-scale refactoring that moved the primary data carrier inside the zip from JSON to SQLite, which is inconvenient to read from within a Flutter app. If you are migrating from v1.2.x, follow the in-app prompt to visit the website for compatibility conversion.
  - The auxiliary website provided in-app, kelivo-helper.netlify.app, processes data entirely locally — your data is never uploaded to a server.
- **Package name changed to avoid conflicts.** Many developers worry that their custom changes will conflict with future Kelivo updates; but installing Cuplivo **does not require uninstalling and will not overwrite** Kelivo — your data is doubly protected.
- **UI inherits Kelivo's style.** No major changes overall; existing users will feel right at home.

### 🧪 Stability

This fork is positioned as a **"new feature proving ground"**: it may adopt features the community finds useful, most verified through lightweight self-testing, aiming to provide a more out-of-the-box experience for users seeking the latest capabilities. Basic availability and stability are maintained, but releases are more frequent with lighter review — there may be bugs, though feedback will be addressed promptly.

## ✨ New Features

Unlike most personal-customization or single-feature forks, Cuplivo aims to add multiple features for a broader audience to try out. Some items may be removed as upstream (Kelivo) adds their counterparts.

### Signature Chat Experience

1. **Flexible file system operations** — Weighty Linux sandbox and lightweight file system access: the full Linux sandbox on **Android** can select a distribution in-app and open a Termux-like interactive terminal from workspace settings (independent of the model shell tool), and can mount external directories (SAF) into the workspace with scheduled syncing; **iOS** runs the sandbox via iSH; users who complete the setup can execute command-line tools. For lighter tasks, the built-in filesystem MCP server reads, writes and regex-searches local files through an in-memory server and mounts local directories without a command line (security-first), with an in-app file browser, paginated grep results and context, code structure outlines, downloading internet resources into the workspace, and long-webpage workspace cache continuation; on desktop, the built-in workspace directory location is user-configurable, with open-externally and share actions for workspace files.

2. **Proactive care** — AI can proactively send care messages to users on a configurable schedule (Android only).
   - *Android-only*: background alarm + notification channel; alarm persists through force-stop
   - *Tip*: Enable it in the "Ta's Letters" tab of the assistant settings

3. **Multi-assistant group chat** — Director-orchestrated group conversations: a background director model decides which assistant speaks, and each member chats in a shared thread with private context.

4. **Incremental backup & LAN sync** — Uploads only conversations, messages and related attachments since a selected date; quickly sync two devices' state over LAN, avoiding the need to transfer huge zip files over the public internet on every sync.
   - *In practice*: A 12.6 MB full backup is typically followed by incremental uploads of 50 KB to 1.5 MB. Savings become more apparent as attachments and images accumulate. This reduces bandwidth and storage overhead, encouraging more frequent backups.
   - *Note*: Periodic full snapshots are still recommended to protect against large data loss.

5. **Multi-AI side-by-side comparison** — Select 2 or more models to answer simultaneously and compare their responses side by side — pick the best result, or synthesize them into a single reply via summary, fusion, or commentary (like a more flexible OpenRouter Fusion).
   - *Tip*: Multi-select models in the model picker before sending a message to activate this mode.

6. **Import from RikkaHub** — Convert a RikkaHub backup into a Cuplivo-compatible backup through the migration website, then import it via "Import Backup File".

### Agent Capabilities

1. **Handoff (subagent delegation)** — Delegate subtasks to other assistants via MCP tools: fire-and-forget for background work, or **wait mode** that blocks until the subagent finishes and returns its result to the main agent for further processing, with a live progress panel in the parent conversation and same-turn parallel calls.

2. **Skills** — Import skills from public GitHub repositories, plus auxiliary file tools for skill execution. Skills are persisted on the filesystem and included in backups. v3 adds categories, a master toggle, chat-level skill entry, and built-in tools that let the assistant import and create skills directly.

### API & Provider Control

1. **Image generation options panel** — Visual configuration for OpenAI Images API models: quickly control quality, size/aspect ratio, output format, count, and more.

2. **OAuth account sign-in** — Device-code sign-in for Grok xAI and OpenAI Codex, so you can use your subscriptions in Cuplivo.

3. **Smart OCR mode** — New "Smart" OCR mode: OCR stays off for vision-capable models and turns on for those without vision; per-assistant auto/always/never control.

4. **PDF/Office file attachments** — Upload PDF, Word, Excel, and PowerPoint documents directly as attachments, with configurable document processing options.

### Practical Utilities

1. **Message reply** — QQ-style message-level reply: quote via long-press text selection or the message-level "More" menu; citations are displayed smartly and trimmed for context.

2. **Input drafts** — Typed input is saved as a draft and restored when the app restarts, so your last unsent content survives a relaunch.

3. **Enhanced assistant message direct copy** — Naive subsequence Markdown copy + quote for quick message extraction.

4. **Math formula export** — Block-level formulas can be copied as LaTeX / copied as PNG / downloaded as PNG.

5. **AI log analysis** — Ask AI to analyze redacted request logs with a one-click draft right from the request log UI.

6. **Tools Hub** — MCP servers, local tools, and workspace management (including mounts and Android terminal launch) unified into the original MCP entry, for quick adjustments during chat.

7. **Startup assistant pin** — Choose an assistant that gets auto-selected when the app restarts, keeping your preferred assistant across sessions.

8. **World book discovery** — Expanding the input bar shows world books grouped, and active assistants can be bound quickly while creating/editing entries.

9. **Conversation export to PDF** — Export the current conversation to PDF via the WebView renderer on Windows and Android.

### UI & Rendering

1. **Web conversation view (experimental)** — Enable the experimental toggle to render standard conversations in a WebView on Android/iOS/macOS/Windows, with a declarative "Web conversation style library" JSON style import for bubble and card styling.

2. **Reading mode** — Long assistant answers can open in a dedicated reading mode to reduce fatigue.

3. **SVG preview** — Renders SVG diagrams inline within `svg` code blocks.

4. **Preset messages** — Preset messages collapsed behind a toggle bar in the chat list; new conversations are blocked when only presets exist.

### Additional Fixes

- Markdown math formulas now render correctly: multi-line formulas inside lists, plus `\tag` support
- Win+V clipboard history paste fix for Flutter engine bug on Windows
- Kaomoji rendering — A bundled fallback font covers rare characters so kaomoji are no longer rendered incorrectly
- Various other stability improvements

## ⚠️ Note

Cuplivo is a community fork and has not been fully separated from the upstream project; some references may retain the original name. Dedicated QQ group and Discord channel have been set up. The app icon has been replaced with Cuplivo's custom artwork (commissioned by @Pheobe-Southwood).

---

<div align="center">
  <img src="docx/screenshot_1.png" alt="Chat Screen" width="150" />
  <img src="docx/screenshot_2.png" alt="Model Selection" width="150" />
  <img src="docx/screenshot_3.png" alt="Tool Calling" width="150" />
  <img src="docx/screenshot_4.png" alt="Web Search" width="150" />
</div>

## 🚀 Download

🔗 [Download the latest version](https://github.com/cuplivo/cuplivo/releases/latest)

> **iOS:** Cuplivo is not on the App Store. Please install it by self-signing (e.g. Sideloadly, AltStore, or other signing tools).

## 💖 Sponsors

Thanks to [siliconflow.cn](https://siliconflow.cn) for providing free models in cooperation with Kelivo.

## ✨ Features

- 🎨 **Modern Design** - Material You design language with dynamic color theming support (Android 12+).
- 🌙 **Dark Mode** - Perfectly adapted dark theme to protect your eyes.
- 🌍 **Multi-language Support** - Supports both English and Chinese interfaces.
- 🖥️ **Multi-platform Support** - Mobile (Android/iOS) and Desktop (Windows/macOS/Linux).
- 🔄 **Multi-provider Support** - Supports major AI providers like OpenAI, Google Gemini, Anthropic, DeepSeek, etc.
- 🤖 **Custom Assistants** - Create and manage personalized AI assistants.
- 🖼️ **Multimodal Input** - Supports various formats including images, text documents, PDFs, Word documents, etc.
- 📝 **Markdown Rendering** - Supports code highlighting, LaTeX formulas, tables, and more.
- 🎙️ **Voice/TTS Providers** - Built-in system TTS plus OpenAI / Google Gemini / ElevenLabs voice servers.
- 🛠️ **MCP Support** - Model Context Protocol tool integration.
- 🔍 **Web Search** - Integrated with multiple search engines (Bing, DuckDuckGo, Exa, Tavily, Zhipu, LinkUp, Brave, Metaso, SearXNG, Ollama, Jina, Perplexity, Bocha, Serper, Grok).
- 📤 **QR Code Sharing** - Export and import provider configurations via QR codes.
- 🌐 **Custom Requests** - Supports custom HTTP request headers and bodies.
- 🔡 **Custom Fonts** - Bring your own fonts (system fonts / Google Fonts).

## 📱 Platform Support

- ✅ Android
- ✅ iOS
- ✅ Windows
- ✅ macOS
- ✅ Linux

## ❤️ Acknowledgements

Special thanks to the [RikkaHub](https://github.com/re-ovo/rikkahub) project for the UI design inspiration. Kelivo's interface design is heavily inspired by RikkaHub's beautiful and practical design.

Special thanks to [OpenCode](https://opencode.ai) — the design of our file system tools is heavily inspired by OpenCode.

## 📄 License

Like Kelivo, this project is licensed under the AGPL-3.0 License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">
Made with ❤️ using Flutter
</div>
