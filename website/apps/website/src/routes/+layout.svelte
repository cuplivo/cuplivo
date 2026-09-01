<script lang="ts">
  import '../app.css';
  let { children } = $props();

  const navItems = [
    { href: '/#product', label: '产品' },
    { href: '/tools/migrate', label: '工具' },
    { href: '/#download', label: '下载' },
    { href: 'https://github.com/cuplivo/cuplivo#readme', label: '文档' },
  ];
</script>

<div class="min-h-screen bg-gray-50 text-gray-800">
  <header class="bg-white border-b border-gray-200 sticky top-0 z-10">
    <div class="max-w-5xl mx-auto px-4 py-3 flex items-center gap-6">
      <a class="font-bold text-lg text-blue-600 hover:text-blue-700" href="/">Cuplivo</a>
      <nav class="flex gap-1">
        {#each navItems as item}
          <a
            class="px-3 py-1.5 rounded-lg text-sm text-gray-600 hover:bg-gray-100 transition-colors"
            href={item.href}
          >{item.label}</a>
        {/each}
      </nav>
    </div>
  </header>

  <main class="max-w-5xl mx-auto px-4 py-8">
    {@render children()}
  </main>

  <footer class="max-w-5xl mx-auto px-4 py-6 text-xs text-gray-400">
    所有处理均在浏览器本地完成，数据不会上传。 ·
    <a class="hover:text-gray-600" href="https://github.com/cuplivo/cuplivo" target="_blank" rel="noreferrer">GitHub</a>
  </footer>
</div>
