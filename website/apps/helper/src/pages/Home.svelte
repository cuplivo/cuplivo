<script lang="ts">
  import { navigate } from '../lib/view.svelte';

  const tools: { id: 'migrate' | 'recover' | 'compat'; title: string; desc: string; icon: string }[] = [
    {
      id: 'migrate',
      title: '迁移',
      desc: '将 RikkaHub 备份包转换为 Kelivo 可恢复的备份包：会话、消息、助手、提供商与设置全量映射，附迁移报告。',
      icon: '🔄',
    },
    {
      id: 'compat',
      title: '兼容',
      desc: '将 Kelivo v1.2.0 备份包转换为 Cuplivo v2.7.1 可恢复的备份包：SQLite 快照读出，chats.json（version 1）写出，附兼容报告。',
      icon: '🔀',
    },
    {
      id: 'recover',
      title: '恢复',
      desc: '缺失助手重建占位、孤儿消息重建会话壳、null 会话挂载到恢复助手——一次扫描全部完成。',
      icon: '🧩',
    },
  ];
</script>

<div class="space-y-8">
  <section class="text-center py-10">
    <h1 class="text-3xl font-extrabold text-gray-900">Kelivo 数据工具箱</h1>
    <p class="mt-3 text-gray-500 max-w-xl mx-auto">
      面向 Kelivo 用户的纯前端工具：解析 Kelivo / RikkaHub 的备份导出包，提供迁移、找回、修复能力。
      所有处理均在浏览器本地完成，数据不出浏览器。
    </p>
  </section>

  <section class="grid md:grid-cols-2 gap-4">
    {#each tools as tool}
      <button
        class="text-left bg-white border border-gray-200 rounded-xl p-6 shadow-sm hover:shadow-md hover:border-blue-300 transition-all"
        onclick={() => navigate(tool.id)}
      >
        <div class="text-2xl mb-3">{tool.icon}</div>
        <div class="font-bold text-gray-900 mb-1">{tool.title}</div>
        <p class="text-sm text-gray-500 leading-relaxed">{tool.desc}</p>
      </button>
    {/each}
  </section>
</div>
