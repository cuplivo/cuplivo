<script lang="ts">
  // —— Cuplivo 相对 Kelivo 的差异化能力（提炼自 README_ZH_CN「✨ 新功能」） ——
  const features = [
    {
      icon: '📦',
      title: '增量备份 & 局域网同步',
      desc: '仅上传选定日期以来的对话、消息与附件；实测 12.6 MB 全量备份后，增量仅 50 KB–1.5 MB。局域网内两台设备快捷同步。',
    },
    {
      icon: '🗑️',
      title: '删除恢复（回收站）',
      desc: '删除的对话进入回收站，容量上限可配置（默认 10 KB）；同步携带删除标记，一端删除的内容在另一端及时清除。',
    },
    {
      icon: '🐧',
      title: 'Linux 沙箱',
      desc: '运行完整 Linux 沙箱：Android 应用内选择发行版，iOS 经 iSH 运行；类 Termux 交互终端、SAF 挂载外部目录。',
    },
    {
      icon: '⚖️',
      title: '多 AI 横向对比',
      desc: '选择 2 个及以上模型同时回答，同屏横向对比；择优采用，或将多份回复总结、融合、评论合成为一个回复。',
    },
    {
      icon: '🎭',
      title: '多助手群聊',
      desc: '导演模型编排的群聊：后台导演决定哪位助手发言，成员在共享对话中聊天，各自持有私有上下文。',
    },
    {
      icon: '🗂️',
      title: '内置文件系统 MCP',
      desc: '内存 MCP 服务器读、写、正则查找本地文件；免命令行挂载本地目录，grep 分页与上下文，查看代码架构。',
    },
    {
      icon: '🤝',
      title: '子代理委派（Handoff）',
      desc: '通过 MCP 工具把子任务委派给其他助手：即发即忘跑后台，或等待模式取回结果；实时进度看板，同轮并发。',
    },
    {
      icon: '🧠',
      title: '技能（Skills）',
      desc: '从公开 GitHub 仓库导入技能；持久化于文件系统并随备份包含，v3 支持分类、总开关与对话级入口。',
    },
  ];

  const platforms = ['Android', 'iOS', 'Windows', 'macOS', 'Linux'];

  const tools = [
    {
      href: '/tools/migrate',
      icon: '🔄',
      title: '迁移',
      desc: '将 RikkaHub 备份包转换为 Kelivo 可恢复的备份包：会话、消息、助手、提供商与设置全量映射，附迁移报告。',
    },
    {
      href: '/tools/compat',
      icon: '🔀',
      title: '兼容',
      desc: '将 Kelivo v1.2.0 备份包转换为 Cuplivo v2.7.1 可恢复的备份包：SQLite 快照读出，chats.json（version 1）写出，附兼容报告。',
    },
    {
      href: '/tools/recovery',
      icon: '🧩',
      title: '恢复',
      desc: '缺失助手重建占位、孤儿消息重建会话壳、null 会话挂载到恢复助手——一次扫描全部完成。',
    },
  ];
</script>

<svelte:head>
  <title>Cuplivo — 开源跨平台 LLM 聊天客户端</title>
  <meta
    name="description"
    content="Cuplivo 官网：开源跨平台 LLM 聊天客户端（Kelivo 社区分支），与浏览器端备份工具（迁移 / 兼容 / 恢复）。"
  />
</svelte:head>

<div class="space-y-16">
  <!-- Hero / 产品 -->
  <section id="product" class="text-center py-12 scroll-mt-16">
    <h1 class="text-4xl font-extrabold text-gray-900">Cuplivo</h1>
    <p class="mt-4 text-lg text-gray-600 max-w-2xl mx-auto">
      开源跨平台 LLM 聊天客户端 —— Kelivo 社区分支，定位「新功能试验场」。
      Android / iOS / Windows / macOS / Linux 全平台，备份格式与 Kelivo 兼容，无缝衔接。
    </p>
    <div class="mt-8 flex justify-center gap-3 flex-wrap">
      <a
        class="bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium px-6 py-2.5 rounded-lg transition-colors"
        href="#download">下载应用</a>
      <a
        class="bg-gray-100 hover:bg-gray-200 text-gray-700 text-sm font-medium px-6 py-2.5 rounded-lg transition-colors"
        href="#features">看看新功能</a>
      <a
        class="bg-gray-100 hover:bg-gray-200 text-gray-700 text-sm font-medium px-6 py-2.5 rounded-lg transition-colors"
        href="https://github.com/cuplivo/cuplivo" target="_blank" rel="noreferrer">GitHub</a>
    </div>
    <div class="mt-8 flex justify-center gap-2 flex-wrap text-xs text-gray-500">
      {#each platforms as p}
        <span class="border border-gray-200 bg-white rounded-full px-3 py-1">{p}</span>
      {/each}
    </div>
  </section>

  <!-- 从 Kelivo 迁移 -->
  <section class="bg-white border border-gray-200 rounded-xl shadow-sm px-6 py-6">
    <h2 class="font-bold text-gray-900 mb-3">来自 Kelivo？</h2>
    <ul class="space-y-2 text-sm text-gray-600">
      <li>· 备份 zip 格式兼容：在 Kelivo 导出备份文件，在 Cuplivo 恢复即可继续使用，无需重新配置。</li>
      <li>· 可与 Kelivo 共存：安装 Cuplivo 无需卸载 Kelivo，也不覆盖其数据。</li>
      <li>· 界面风格继承 Kelivo，原有用户可以快速适应。</li>
    </ul>
  </section>

  <!-- 差异化特性 -->
  <section id="features" class="scroll-mt-16">
    <div class="text-center mb-6">
      <h2 class="text-2xl font-bold text-gray-900">Cuplivo 新功能</h2>
      <p class="mt-2 text-sm text-gray-500">
        相对 Kelivo 的增量能力——完整清单见
        <a
          class="text-blue-600 hover:text-blue-700"
          href="https://github.com/cuplivo/cuplivo#readme"
          target="_blank"
          rel="noreferrer">GitHub README</a>
      </p>
    </div>
    <div class="grid sm:grid-cols-2 lg:grid-cols-4 gap-4">
      {#each features as f}
        <div class="bg-white border border-gray-200 rounded-xl p-5 shadow-sm">
          <div class="text-2xl mb-2">{f.icon}</div>
          <div class="font-bold text-gray-900 mb-1">{f.title}</div>
          <p class="text-sm text-gray-500 leading-relaxed">{f.desc}</p>
        </div>
      {/each}
    </div>
    <p class="mt-6 text-center text-xs text-gray-400">
      Kelivo 的全部基础能力同样具备：多提供商、MCP、网页搜索、Markdown/LaTeX、多模态输入、语音 TTS……
    </p>
  </section>

  <!-- 下载 -->
  <section id="download" class="text-center py-8 scroll-mt-16">
    <h2 class="text-2xl font-bold text-gray-900">下载</h2>
    <p class="mt-2 text-sm text-gray-500">最新版本发布在 GitHub Releases</p>
    <a
      class="inline-block mt-6 bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium px-8 py-3 rounded-lg transition-colors"
      href="https://github.com/cuplivo/cuplivo/releases/latest"
      target="_blank" rel="noreferrer">前往 GitHub Releases</a>
    <p class="mt-4 text-xs text-gray-400">
      iOS 未上架 App Store，请通过自签方式安装（Sideloadly、AltStore 等签名工具）。
    </p>
  </section>

  <!-- 工具 -->
  <section id="tools" class="scroll-mt-16">
    <div class="text-center mb-6">
      <h2 class="text-2xl font-bold text-gray-900">在线数据工具</h2>
      <p class="mt-2 text-sm text-gray-500">
        解析 Kelivo / RikkaHub 备份导出包，提供迁移、找回、修复能力。
        <strong>所有处理均在浏览器本地完成，数据不出浏览器。</strong>
      </p>
    </div>
    <div class="grid md:grid-cols-3 gap-4">
      {#each tools as tool}
        <a
          class="text-left bg-white border border-gray-200 rounded-xl p-6 shadow-sm hover:shadow-md hover:border-blue-300 transition-all"
          href={tool.href}>
          <div class="text-2xl mb-3">{tool.icon}</div>
          <div class="font-bold text-gray-900 mb-1">{tool.title}</div>
          <p class="text-sm text-gray-500 leading-relaxed">{tool.desc}</p>
        </a>
      {/each}
    </div>
  </section>
</div>
