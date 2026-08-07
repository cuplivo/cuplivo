<script lang="ts">
  import ZipDropzone from '../lib/ui/ZipDropzone.svelte';
  import { recoverAssistants, type AssistantRecoveryResult } from '../lib/kelivo/assistant-recovery';
  import { loadZip, downloadBlob } from '../lib/zip';

  let processing = $state(false);
  let error = $state<string | null>(null);
  let result = $state<AssistantRecoveryResult | null>(null);

  async function handleFile(file: File) {
    processing = true;
    error = null;
    result = null;
    try {
      const zip = await loadZip(file);
      result = await recoverAssistants(zip, file.name);
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
    <h1 class="text-2xl font-bold text-gray-900">助手找回</h1>
    <p class="mt-1 text-sm text-gray-500">
      扫描 chats.json 中出现过但缺失于 assistants_v1 的 assistantId，重建占位助手并写回 settings.json。
    </p>
  </header>

  <div class="p-4 bg-amber-50 border-l-4 border-amber-500 rounded text-xs text-amber-900 leading-relaxed">
    <ul class="list-disc pl-4 space-y-1">
      <li>仅通过 chats.json 中的 assistantId 重建最基础的助手占位符，无法恢复原助手的真实 System Prompt、头像、模型参数等。</li>
      <li>所有重建的助手统一命名为 <code class="bg-amber-100 px-1 rounded">Found 01</code>、<code class="bg-amber-100 px-1 rounded">Found 02</code>… 并使用默认参数。</li>
      <li>此操作只读修改 settings.json 中的助手列表，对话历史与其他文件原样保留。</li>
    </ul>
  </div>

  {#if !result}
    <ZipDropzone label="Kelivo 备份 zip（v1.1.17 或 v2.x 均可）" onFile={handleFile} />
  {/if}

  {#if processing}
    <div class="text-center py-6 text-sm text-blue-600 font-medium">正在扫描并重建助手…</div>
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
            识别到缺失助手 {result.missingCount} 个，新建占位助手 {result.createdCount} 个
          </p>
        </div>
        <button
          class="bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          onclick={download}
        >下载修复后的 ZIP</button>
      </div>

      <div class="px-6 py-4 max-h-96 overflow-y-auto space-y-3">
        {#each result.missing as item}
          <div class="border border-gray-200 rounded-lg p-3">
            <div class="flex items-center justify-between">
              <span class="font-bold text-sm text-gray-800">
                {item.created ? `Found ${String(result.missing.findIndex((x) => x.assistantId === item.assistantId) + 1).padStart(2, '0')}` : item.assistantId}
              </span>
              <span class="text-[10px] bg-blue-100 text-blue-800 px-2 py-0.5 rounded-full font-mono">
                {item.assistantId.slice(0, 8)}…
              </span>
            </div>
            <p class="text-xs text-gray-400 mt-1 font-mono break-all">ID: {item.assistantId}</p>
            {#if item.titles.length > 0}
              <div class="mt-2 bg-gray-50 p-2 rounded">
                <p class="text-[11px] font-semibold text-gray-500 mb-1">采样历史对话</p>
                <ul class="space-y-0.5">
                  {#each item.titles as t}
                    <li class="text-xs text-gray-600 truncate">• {t}</li>
                  {/each}
                </ul>
              </div>
            {/if}
          </div>
        {/each}
      </div>

      <div class="px-6 py-3 border-t border-gray-100">
        <button class="text-sm text-blue-600 hover:text-blue-700 font-medium" onclick={() => (result = null)}>
          重新上传
        </button>
      </div>
    </section>
  {/if}
</div>
