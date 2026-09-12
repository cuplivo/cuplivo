<div align="center">
  <img src="assets/app_icon.png" alt="Cuplivo Icon" width="100" />
  <h1>Why Cuplivo?</h1>

  A Flutter LLM Chat Client — A community fork
  
  Cuplivo official QQ group: `1101061750`

  [阅读简体中文文档](README_ZH_CN.md)快速查看特性
</div>

> [!IMPORTANT]
> **Project Status (2026-09-12)**
>
> In a single week, Kelivo cleared half of Cuplivo's added features — with far greater completeness. Cuplivo has since diverged dramatically from Kelivo, and many parts of its architecture remain incomplete because it missed one large migration.
>
> Meanwhile, given the developers' limited time and energy, Cuplivo can hardly keep pace with Kelivo going forward, and the day-to-day friction of iOS self-signing is still far from resolved. From now on we will move to Kelivo's Issues and PRs, contributing to Kelivo's progress as one unified project.
>
> Since v1.2.0 (2026-07-02), Cuplivo shipped 41 releases over more than two months of active development and reached 63 stars — the longest-lived and most feature-rich fork in Kelivo's history.
>
> Cuplivo also contributed design inspiration to many of Kelivo's implementations (and helped nudge the mainline forward), stepped through plenty of pitfalls, and fully lived up to its role as Kelivo's proving ground. As for the remaining features, LAN sync in particular, we hope Kelivo ships them soon.
>
> On 2026-09-12, Cuplivo released v3.2.1, its 42nd release, closing this chapter. The repository will not be archived for now, and the QQ group will remain open.
>
> Thank you to everyone who came along. We will still meet in Kelivo.
>
> To those days of hard work.

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

1. **Proactive care** — AI can proactively send care messages to users on a configurable schedule (Android only).
   - *Android-only*: background alarm + notification channel; alarm persists through force-stop
   - *Tip*: Enable it in the "Ta's Letters" tab of the assistant settings

2. **Multi-assistant group chat** — Director-orchestrated group conversations: a background director model decides which assistant speaks, and each member chats in a shared thread with private context.

3. **Incremental backup & LAN sync** — Uploads only conversations, messages and related attachments since a selected date; quickly sync two devices' state over LAN, avoiding the need to transfer huge zip files over the public internet on every sync. The client remembers recent endpoints, and the server can show a QR code / copy-link for quick connect.
   - *In practice*: A 12.6 MB full backup is typically followed by incremental uploads of 50 KB to 1.5 MB. Savings become more apparent as attachments and images accumulate. This reduces bandwidth and storage overhead, encouraging more frequent backups.
   - *Note*: Periodic full snapshots are still recommended to protect against large data loss.

4. **Multi-AI side-by-side comparison** — Select 2 or more models to answer simultaneously and compare their responses side by side — pick the best result, or synthesize them into a single reply via summary, fusion, or commentary (like a more flexible OpenRouter Fusion).
   - *Tip*: Multi-select models in the model picker before sending a message to activate this mode.

### API & Provider Control

1. **Image generation options panel** — Visual configuration for OpenAI Images API models: quickly control quality, size/aspect ratio, output format, count, and more.

2. **OAuth account sign-in** — Device-code sign-in for Grok xAI and OpenAI Codex, so you can use your subscriptions in Cuplivo.

3. **Smart OCR mode** — New "Smart" OCR mode: OCR stays off for vision-capable models and turns on for those without vision; per-assistant auto/always/never control.

4. **PDF/Office file attachments** — Upload PDF, Word, Excel, and PowerPoint documents directly as attachments, with configurable document processing options.

5. **Per-model reasoning-effort override** — Declare which reasoning levels a niche or unlisted model actually supports, so higher levels such as `xhigh` are no longer clamped down.

### Practical Utilities

1. **Message reply** — QQ-style message-level reply: quote via long-press text selection or the message-level "More" menu; citations are displayed smartly and trimmed for context.

2. **Input drafts** — Typed input is saved as a draft and restored when the app restarts, so your last unsent content survives a relaunch.

3. **Enhanced assistant message direct copy** — Naive subsequence Markdown copy + quote for quick message extraction.

4. **Math formula export** — Block-level formulas can be copied as LaTeX / copied as PNG / downloaded as PNG.

5. **AI log analysis** — Ask AI to analyze redacted request logs with a one-click draft right from the request log UI.

6. **Startup assistant pin** — Choose an assistant that gets auto-selected when the app restarts, keeping your preferred assistant across sessions.

7. **World book discovery** — Expanding the input bar shows world books grouped, and active assistants can be bound quickly while creating/editing entries.

8. **Conversation export to PDF** — Export the current conversation to PDF via the WebView renderer on Windows and Android.

9. **Save temporary conversations** — Temporary conversations can be promoted to history with one tap.

10. **User-managed translation target languages** — Manage the translation target-language list yourself; the catalog covers 16 languages including Bengali.

11. **Statistics filters** — Filter the statistics page by model/provider, assistant and topic; overview metrics, heatmap, usage trend and rankings all react to the filter.

### UI & Rendering

1. **Web conversation view (experimental)** — Enable the experimental toggle to render standard conversations in a WebView on Android/iOS/macOS/Windows, with a declarative "Web conversation style library" JSON style import for bubble and card styling.

2. **Reading mode** — Long assistant answers can open in a dedicated reading mode to reduce fatigue.

### Additional Fixes

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

> **iOS:** Cuplivo is not on the App Store. Please install it by self-signing (e.g. Sideloadly, AltStore, or other signing tools). Inbound share requires an App Group entitlement, which free Apple IDs cannot provision — use a paid Apple Developer account or a signing tool that supports App Groups.

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
