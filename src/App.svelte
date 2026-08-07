<script lang="ts">
  import Home from './pages/Home.svelte';
  import Migrate from './pages/Migrate.svelte';
  import Recovery from './pages/Recovery.svelte';
  import { router, navigate } from './lib/view.svelte';

  const navItems: { id: 'migrate' | 'recover'; label: string }[] = [
    { id: 'migrate', label: '杩佺Щ' },
    { id: 'recover', label: '鎭㈠' },
  ];
</script>

<div class="min-h-screen bg-gray-50 text-gray-800">
  <header class="bg-white border-b border-gray-200 sticky top-0 z-10">
    <div class="max-w-5xl mx-auto px-4 py-3 flex items-center gap-6">
      <button
        class="font-bold text-lg text-blue-600 hover:text-blue-700"
        onclick={() => navigate('home')}
      >Kelivo Helper</button>
      <nav class="flex gap-1">
        {#each navItems as item}
          <button
            class="px-3 py-1.5 rounded-lg text-sm transition-colors {router.view === item.id
              ? 'bg-blue-50 text-blue-700 font-medium'
              : 'text-gray-600 hover:bg-gray-100'}"
            onclick={() => navigate(item.id)}
          >{item.label}</button>
        {/each}
      </nav>
    </div>
  </header>

  <main class="max-w-5xl mx-auto px-4 py-8">
    {#if router.view === 'home'}
      <Home />
    {:else if router.view === 'migrate'}
      <Migrate />
    {:else}
      <Recovery />
    {/if}
  </main>

  <footer class="max-w-5xl mx-auto px-4 py-6 text-xs text-gray-400">
    鎵€鏈夊鐞嗗潎鍦ㄦ祻瑙堝櫒鏈湴瀹屾垚锛屾暟鎹笉浼氫笂浼犮€?  </footer>
</div>
