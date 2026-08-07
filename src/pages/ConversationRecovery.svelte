<script lang="ts">
  import ZipDropzone from '../lib/ui/ZipDropzone.svelte';
  import { recoverConversations, type ConversationRecoveryResult } from '../lib/kelivo/conversation-recovery';
  import { loadZip, downloadBlob } from '../lib/zip';

  let processing = $state(false);
  let error = $state<string | null>(null);
  let result = $state<ConversationRecoveryResult | null>(null);

  async function handleFile(file: File) {
    processing = true;
    error = null;
    result = null;
    try {
      const zip = await loadZip(file);
      result = await recoverConversations(zip, file.name);
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
    <h1 class="text-2xl font-bold text-gray-900">对话找回</h1>
    <p class="mt-1 text-sm text-gray-500">
      conversation 条目损坏/丢失但消息幸存时，按 ChatMessage.conversationId 分组重建会话壳。
    </p>
  </header>

  <div class="p-4 bg-amber-50 border-l-4 border-amber-500 rounded text-xs text-amber-900 leading-relaxed">
    <ul class="list-disc pl-4 space-y-1">
      <li>重建的会话壳：id、title（取首条 user 消息）、messageIds、时间戳；<strong>assistantId 为 null</strong>，助手归属不可恢复。</li>
      <li>title、isPinned、summary 等元数据随会话条目一起丢失，无法找回。</li>
      <li><strong>已删对话不可恢复</strong>：deleted.json 只含墓碑（id + 删除时间），没有内容。</li>
    </ul>
  </div>

  {#if !result}
    <ZipDropzone label="Kelivo 备份 zip（v1.1.17 或 v2.x 均可）" onFile={handleFile} />
  {/if}

  {#if processing}
    <div class="text-center py-6 text-sm text-blue-600 font-medium">正在扫描孤儿消息并重建会话…</div>
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
            孤儿消息 {result.orphanCount} 条 → 重建会话 {result.restoredCount} 个
          </p>
        </div>
        <button
          class="bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          onclick={download}
        >下载修复后的 ZIP</button>
      </div>

      <div class="px-6 py-4 max-h-96 overflow-y-auto space-y-2">
        {#each result.restored as r}
          <div class="border border-gray-200 rounded-lg p-3">
            <div class="flex items-center justify-between gap-2">
              <span class="font-bold text-sm text-gray-800 truncate">{r.title}</span>
              <span class="text-[10px] bg-blue-100 text-blue-800 px-2 py-0.5 rounded-full whitespace-nowrap">
                {r.messageCount} 条消息
              </span>
            </div>
            <p class="text-xs text-gray-400 mt-1 font-mono break-all">ID: {r.conversationId}</p>
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
