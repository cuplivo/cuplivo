<script lang="ts">
  import ZipDropzone from '../lib/ui/ZipDropzone.svelte';
  import { runRecovery, RECOVERY_ASSISTANT_NAME, type RecoveryResult } from 'helper-core/kelivo/recovery';
  import { loadZip, downloadBlob } from 'helper-core/zip';

  let processing = $state(false);
  let error = $state<string | null>(null);
  let result = $state<RecoveryResult | null>(null);

  async function handleFile(file: File) {
    processing = true;
    error = null;
    result = null;
    try {
      const zip = await loadZip(file);
      result = await runRecovery(zip, file.name);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      console.error(e);
    } finally {
      processing = false;
    }
  }

  async function download() {
    if (!result) return;
    const blob = await result.outputZip.generateAsync({ type: 'blob' });
    downloadBlob(blob, result.outputName);
  }
</script>

<div class="space-y-6">
  <header>
    <h1 class="text-2xl font-bold text-gray-900">恢复工具</h1>
    <p class="mt-1 text-sm text-gray-500">
      一次扫描完成两项能力：<strong>助手找回</strong>（缺失助手重建占位）与
      <strong>对话找回</strong>（孤儿消息重建会话壳）；同时把
      <code class="bg-gray-100 px-1 rounded">assistantId</code> 为 null 的会话挂载到恢复助手。
    </p>
  </header>

  <div class="p-4 bg-amber-50 border-l-4 border-amber-500 rounded text-xs text-amber-900 leading-relaxed">
    <ul class="list-disc pl-4 space-y-1">
      <li>重建的助手为占位符（<code class="bg-amber-100 px-1 rounded">Found 01</code>…），无法恢复原 System Prompt、头像等；对话历史与其他文件不受影响。</li>
      <li>重建的会话壳与 <code class="bg-amber-100 px-1 rounded">assistantId: null</code> 的会话会挂载到名为
        <code class="bg-amber-100 px-1 rounded">{RECOVERY_ASSISTANT_NAME}</code> 的共享助手——否则在 Kelivo UI 中不可见；title、isPinned 等元数据随之丢失。</li>
      <li><strong>已删对话不可恢复</strong>：deleted.json 只含墓碑（id + 删除时间），没有内容。</li>
    </ul>
  </div>

  {#if !result}
    <ZipDropzone label="Kelivo 备份 zip（v1.1.17 或 v2.x 均可）" onFile={handleFile} />
  {/if}

  {#if processing}
    <div class="text-center py-6 text-sm text-blue-600 font-medium">正在扫描并修复…</div>
  {/if}

  {#if error}
    <div class="p-4 bg-red-50 border-l-4 border-red-500 rounded text-sm text-red-800 break-all">{error}</div>
  {/if}

  {#if result}
    <section class="bg-white border border-gray-200 rounded-xl shadow-sm overflow-hidden">
      <div class="px-6 py-4 border-b border-gray-100 flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 class="font-bold text-gray-900">恢复结果</h2>
          <p class="text-xs text-gray-400 mt-0.5">
            缺失助手 {result.missingAssistants.length} · 新建占位 {result.placeholdersCreated} ·
            孤儿消息 {result.orphanMessages} · 重建会话 {result.shellsRestored} · 挂载 {result.mountedCount}
          </p>
        </div>
        <button
          class="bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          onclick={download}
        >下载修复后的 ZIP</button>
      </div>

      {#if result.warnings.length > 0}
        <div class="px-6 py-3 border-t border-gray-100">
          <h3 class="text-sm font-semibold text-amber-700 mb-2">警告</h3>
          <ul class="space-y-1 text-xs text-amber-800 list-disc pl-4">
            {#each result.warnings as w}<li class="break-all">{w}</li>{/each}
          </ul>
        </div>
      {/if}

      {#if result.mountedCount > 0}
        <div class="px-6 py-3 border-t border-gray-100">
          <h3 class="text-sm font-semibold text-gray-900 mb-1">
            {result.mountedCount} 个会话已挂载到「{RECOVERY_ASSISTANT_NAME}」
          </h3>
          <p class="text-xs text-gray-500">
            其中会话壳 {result.shellsRestored} 个（含 {result.orphanMessages} 条孤儿消息），
            原有 null 会话 {result.mountedCount - result.shellsRestored} 个。
          </p>
        </div>
      {/if}

      {#if result.missingAssistants.length > 0}
        <div class="px-6 py-3 border-t border-gray-100">
          <h3 class="text-sm font-semibold text-gray-900 mb-2">重建的助手（{result.missingAssistants.length}）</h3>
          <div class="space-y-2">
            {#each result.missingAssistants as item}
              <div class="border border-gray-200 rounded-lg p-3">
                <div class="flex items-center justify-between">
                  <span class="font-bold text-sm text-gray-800">
                    Found {String(result.missingAssistants.indexOf(item) + 1).padStart(2, '0')}
                  </span>
                  <span class="text-[10px] bg-blue-100 text-blue-800 px-2 py-0.5 rounded-full font-mono">
                    {item.assistantId.slice(0, 8)}…
                  </span>
                </div>
                <p class="text-xs text-gray-400 mt-1 font-mono break-all">ID: {item.assistantId}</p>
                {#if item.titles.length > 0}
                  <ul class="mt-2 space-y-0.5">
                    {#each item.titles as t}
                      <li class="text-xs text-gray-600 truncate">• {t}</li>
                    {/each}
                  </ul>
                {/if}
              </div>
            {/each}
          </div>
        </div>
      {/if}

      <div class="px-6 py-3 border-t border-gray-100">
        <button class="text-sm text-blue-600 hover:text-blue-700 font-medium" onclick={() => (result = null)}>
          重新上传
        </button>
      </div>
    </section>
  {/if}
</div>
