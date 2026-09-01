<script lang="ts">
  import { page } from '$app/state';
  let { children } = $props();

  const tools = [
    { href: '/tools/migrate', label: '迁移' },
    { href: '/tools/compat', label: '兼容' },
    { href: '/tools/recovery', label: '恢复' },
  ];
</script>

<div class="space-y-6">
  <nav class="flex gap-1">
    {#each tools as tool}
      <a
        class="px-3 py-1.5 rounded-lg text-sm transition-colors {page.url.pathname === tool.href
          ? 'bg-blue-50 text-blue-700 font-medium'
          : 'text-gray-600 hover:bg-gray-100'}"
        href={tool.href}
      >{tool.label}</a>
    {/each}
  </nav>
  {@render children()}
</div>
