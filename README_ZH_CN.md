<div align="center">
  <img src="assets/app_icon.png" alt="Cuplivo Icon" width="100" />
  <h1>为什么选择 Cuplivo？</h1>

  一个 Flutter LLM 聊天客户端 — 社区分支
  
  Cuplivo 官方 QQ 群 `1101061750`

  [Read the English version](README.md)
</div>

### 🔗 兼容性

Cuplivo 是 Kelivo 的一个社区分支，具有强兼容性：

- 备份 zip 格式兼容。在 Kelivo 选择本地导出，然后在 Cuplivo 恢复备份文件即可无缝接续，无需重新配置。
  - *注意*: Kelivo v1.2.x 进行了大规模的重构，将 zip 内主要信息载体从 json 转移为了 SQLite，不便于在 Flutter 应用内读取。如果您从 v1.2.x 迁移过来，请按照应用内提示前往网站进行兼容性转换。
  - 应用内提供的辅助网站 kelivo-helper.netlify.app 完全在本地处理数据，不会将您的数据上传至服务器，请放心。
- 已更改包名，以避免冲突。许多开发者可能担心自己改的代码实装后与后续 Kelivo 更新冲突；但安装 Cuplivo **无需卸载、不会覆盖** Kelivo，数据安全双重保障。
- 界面风格继承 Kelivo。整体无大幅改动，原有用户可以快速适应。

#### 🧪 稳定性

本 Fork 的定位是"新功能试验场"，可能会添加一些社区认为有用的新功能，大多依赖简易自测，以期为追求新功能的用户提供更加开箱即用的服务。本 Fork 追求基本的可用性和稳定性，但版本发布更加频繁，审查更为宽松，可能存在一些 Bug，但反馈会得到及时处理。

### ✨ 新功能

Cuplivo 与大多数个人定制 / 单功能 Fork 不同，旨在添加多特性以供更广大的受众尝鲜。随着上游（Kelivo）添加对应功能后，部分项目可能会被移除。

#### 提升对话体验的招牌能力

1. **灵活的文件系统操作** — 重量级 Linux 沙箱与轻量级文件系统增删改查：完整 Linux 沙箱 **Android** 可在界面选择发行版，可在工作区设置中打开类 Termux 的交互式终端（与模型 Shell 工具相互独立），还可通过 SAF + 定时同步将外部目录挂载到工作区；**iOS** 通过 iSH 运行沙箱；完成相应配置的用户可以执行命令行工具。轻量级方面：内置文件系统 MCP 服务器通过内存服务器读、写、正则查找本地文件，支持挂载本地目录，无需命令行，安全性优先；挂载后可在应用内文件浏览器中浏览，grep 搜索结果支持分页与上下文，支持查看代码架构、下载互联网资源至工作区，长网页支持工作区缓存续读。电脑端支持自定义内置工作区目录位置，工作区文件支持在外部打开与分享。

2. **Proactive care（Ta的来信）** — AI 可按设定时间主动向用户发送关怀消息（仅 Android）。
   - 仅 Android：后台闹钟 + 通知渠道，闹钟在强制停止后可恢复
   - *提示*：在助手设置的"Ta的来信"标签页中开启

3. **多助手群聊** — 导演模型编排的群聊：后台导演模型决定由哪位助手发言，成员在共享对话中聊天，各自持有私有上下文。

4. **增量备份 & 局域网同步** — 仅上传自某个选定日期以来的对话和消息，以及附件等；在局域网下快捷同步两台设备的状态。避免了每次同步都需要走公网传输极大 zip 文件的麻烦。
   - 实测：一次 12.6 MB 的完整备份后，通常仅会产生 50 KB 至 1.5 MB 的增量上传。随着附件和图片的积累，节省效果会更加明显。这降低了带宽与存储开销，也有助于养成更频繁的备份习惯。
   - 注意：仍建议定期进行完整快照备份，防止大量数据丢失。

5. **多 AI 横向对比** — 选择 2 个及以上模型同时回答，在同一界面横向对比回复。择优采用，也可将多份回复总结、融合或评论合成为一个回复（类似更自由的 OpenRouter Fusion）。
   - *提示*：在模型选择器中多选模型后发送消息即可激活

6. **从 RikkaHub 导入** — 通过迁移网站将 RikkaHub 备份转换为 Cuplivo 兼容的备份，再通过"备份文件导入"导入即可。

#### Agent 能力初步增强

1. **子代理委派 (Handoff)** — 通过 MCP 工具将子任务委派给其他助手执行：即发即忘模式用于后台任务；等待模式下子代理完成后会将结果返回给主代理进一步处理，主对话附有实时进度看板，支持同轮并发调用。

2. **技能 (Skills)** — 从公开 GitHub 仓库导入技能，并提供辅助文件工具。技能持久化存储在文件系统中，并包含在备份中。v3 新增分类、总开关与对话级技能入口；内置工具让助手可直接导入与创建技能。

#### API 调控能力增强

1. **绘图参数面板** — 添加 OpenAI 图像 API 可视化配置，快捷控制质量、尺寸/宽高比、输出格式、数量等参数。

2. **OAuth 账户登录** — Grok xAI 与 OpenAI Codex 支持设备码登录，在 Cuplivo 中使用您的订阅。

3. **OCR 智能模式** — 新增"智能" OCR 模式：模型有视觉能力时关闭 OCR，无视觉能力时开启 OCR；每助手可选自动/始终/关闭。

4. **PDF/Office 文件附件** — 支持直接上传 PDF、Word、Excel、PowerPoint 文档作为附件，并提供文档处理配置选项。

#### 实用能力增强

1. **消息回复** — QQ 风格的消息级回复：长按选中文本引用，或通过消息级"更多"菜单发起；引用内容智能显示并裁剪上下文。

2. **输入草稿** — 输入内容会保存为草稿，应用重启后自动恢复上一次未发送的内容。

3. **增强助手消息直接复制** — 朴素子序列 Markdown 复制 + 引用，快速提取消息内容。

4. **数学公式导出** — 块级公式支持复制为 LaTeX / 复制为 PNG / 下载为 PNG。

5. **AI 日志分析** — 在请求日志界面一键让 AI 分析已脱敏日志。

6. **工具中心 (Tools Hub)** — 将 MCP 服务器、本地工具、工作区管理（含挂载、安卓终端启动）统一到原 MCP 入口，供对话时快捷调整。

7. **启动时固定助手** — 可指定一个助手在应用重启后自动选中，跨会话保持你偏好的助手。

8. **世界书发现增强** — 输入框展开时按分组展示世界书；创建/编辑条目时快捷绑定激活的助手。

9. **对话导出为 PDF** — 将对话导出为 PDF（支持 Windows 与 Android 的 WebView 模式）。

#### 界面渲染功能增强

1. **实验性 Web 对话视图** — 启用实验开关后，Android/iOS/macOS/Windows 的正常对话可切换为 WebView 渲染，并支持导入声明式 "Web 对话样式库" JSON 样式，定制气泡与卡片外观。

2. **阅读模式** — 较长的助手回答可开启阅读模式，降低阅读疲劳。

3. **SVG 预览** — 在 `svg` 代码块内联渲染 SVG 图表。

4. **预设消息** — 预设消息在聊天列表中折叠到切换栏后；仅存在预设消息时阻止新建对话。

#### 其他修复

- Markdown 数学公式渲染：支持列表下的多行公式，支持 `\tag` 渲染
- 修复 Windows 上 Win+V 剪贴板历史粘贴 (Flutter 引擎 Bug 绕过)
- 颜文字修复 — 为冷门字符加入托底字体，防止颜文字被错误渲染
- 其他多项稳定性改进

### ⚠️ 注意事项

Cuplivo 是一个社区分支，未与原项目完全切割，部分地方可能存在名称混用。专门的 QQ 群和 Discord 频道已经建成；App 图标已更换为 Cuplivo 个性图片（由 @Pheobe-Southwood 约稿）。

---

<div align="center">
  <img src="docx/screenshot_1.png" alt="聊天界面" width="150" />
  <img src="docx/screenshot_2.png" alt="模型选择" width="150" />
  <img src="docx/screenshot_3.png" alt="工具调用" width="150" />
  <img src="docx/screenshot_4.png" alt="网络搜索" width="150" />
</div>

## 🚀 下载

🔗 [下载最新版本](https://github.com/cuplivo/cuplivo/releases/latest)

> **iOS**: Cuplivo 未上架 App Store，请通过自签方式安装（如 Sideloadly、AltStore 或其他签名工具）。

## 💖 赞助

感谢 [siliconflow.cn](https://siliconflow.cn) 与 Kelivo 合作提供可免费使用的模型。

## ✨ 功能特性

- 🎨 **现代化设计** - Material You 设计语言，支持动态主题色 (Android 12+)
- 🌙 **深色模式** - 完美适配深色主题，保护您的眼睛
- 🌍 **多语言支持** - 支持中文和英文界面
- 🖥️ **多平台支持** - 移动端与桌面端均支持（Android/iOS、Windows/macOS/Linux）
- 🔄 **多供应商支持** - 支持 OpenAI、Google Gemini、Anthropic、DeepSeek 等主流 AI 供应商
- 🤖 **自定义助手** - 创建和管理个性化 AI 助手
- 🖼️ **多模态输入** - 支持图片、文本文档、PDF、Word 文档等多种格式
- 📝 **Markdown 渲染** - 支持代码高亮、LaTeX 公式、表格等
- 🎙️ **语音服务** - 内置系统 TTS，同时支持 OpenAI / Google Gemini / ElevenLabs 语音服务器
- 🛠️ **MCP 支持** - Model Context Protocol 工具集成
- 🔍 **网络搜索** - 集成多种搜索引擎（Bing、DuckDuckGo、Exa、Tavily、智谱、LinkUp、Brave、Metaso、SearXNG、Ollama、Jina、Perplexity、Bocha、Serper、Grok）
- 📤 **二维码分享** - 通过二维码导出和导入供应商配置
- 🌐 **自定义请求** - 支持自定义 HTTP 请求头和请求体
- 🔡 **自定义字体** - 支持自定义字体（系统字体 / Google Fonts）

## 📱 平台支持

- ✅ Android
- ✅ iOS
- ✅ Windows
- ✅ macOS
- ✅ Linux

## ❤️ 致谢

特别感谢 [RikkaHub](https://github.com/re-ovo/rikkahub) 项目提供的 UI 设计灵感。Kelivo 的界面设计深受 RikkaHub 优美且实用的设计启发。

特别感谢 [OpenCode](https://opencode.ai) — 我们的文件系统工具设计深受 OpenCode 启发。

## 📄 许可证

本项目与 Kelivo 一样采用 AGPL-3.0 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

---

<div align="center">
Made with ❤️ using Flutter
</div>
