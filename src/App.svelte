<script lang="ts">
  import Home from './pages/Home.svelte';
  import Migrate from './pages/Migrate.svelte';
  import AssistantRecovery from './pages/AssistantRecovery.svelte';
  import ConversationRecovery from './pages/ConversationRecovery.svelte';
  import type { View } from './lib/view';

  let view: View = $state('home');

  const navItems: { id: View; label: string; desc: string }[] = [
    { id: 'migrate', label: '迁移', desc: 'RikkaHub 备份 → Kelivo 备份' },
    { id: 'assistant', label: '助手找回', desc: '重建丢失的助手配置' },
    { id: 'conversation', label: '对话找回', desc: '重建丢失的会话' },
  ];
</script>

<div class="min-h-screen bg-gray-50 text-gray-800">
  <header class="bg-white border-b border-gray-200 sticky top-0 z-10">
    <div class="max-w-5xl mx-auto px-4 py-3 flex items-center gap-6">
      <button
        class="font-bold text-lg text-blue-600 hover:text-blue-700"
        onclick={() => (view = 'home')}
      >Kelivo Helper</button>
      <nav class="flex gap-1">
        {#each navItems as item}
          <button
            class="px-3 py-1.5 rounded-lg text-sm transition-colors {view === item.id
              ? 'bg-blue-50 text-blue-700 font-medium'
              : 'text-gray-600 hover:bg-gray-100'}"
            onclick={() => (view = item.id)}
          >{item.label}</button>
        {/each}
      </nav>
    </div>
  </header>

  <main class="max-w-5xl mx-auto px-4 py-8">
    {#if view === 'home'}
      <Home onNavigate={(v) => (view = v)} />
    {:else if view === 'migrate'}
      <Migrate />
    {:else if view === 'assistant'}
      <AssistantRecovery />
    {:else}
      <ConversationRecovery />
    {/if}
  </main>

  <footer class="max-w-5xl mx-auto px-4 py-6 text-xs text-gray-400">
    所有处理均在浏览器本地完成，数据不会上传。
  </footer>
</div>
