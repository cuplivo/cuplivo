<script lang="ts">
  import type JSZip from 'jszip';
  import ZipDropzone from '../lib/ui/ZipDropzone.svelte';
  import { compatKelivoToCuplivo } from 'helper-core/compat';
  import { loadZip, downloadBlob, downloadText } from 'helper-core/zip';
  import { compatReportToMarkdown, type CompatReport } from 'helper-core/compat/report';

  let processing = $state(false);
  let error = $state<string | null>(null);
  let report = $state<CompatReport | null>(null);
  let resultZip: JSZip | null = null;
  let outputName = '';

  async function handleFile(file: File) {
    processing = true;
    error = null;
    report = null;
    resultZip = null;
    try {
      const zip = await loadZip(file);
      const result = await compatKelivoToCuplivo(zip, file.name);
      resultZip = result.outputZip;
      outputName = result.outputName;
      report = result.report;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
      console.error(e);
    } finally {
      processing = false;
    }
  }

  async function downloadCompat() {
    if (!resultZip) return;
    const blob = await resultZip.generateAsync({ type: 'blob' });
    downloadBlob(blob, outputName);
  }
</script>

<div class="space-y-6">
  <header>
    <h1 class="text-2xl font-bold text-gray-900">Kelivo → Cuplivo 兼容</h1>
    <p class="mt-1 text-sm text-gray-500">
      输入 Kelivo v1.2.0 备份 zip（manifest.json + database/kelivo.db + settings.json + 媒体目录），
      输出 Cuplivo v2.7.1 可恢复的备份包与兼容报告。
    </p>
  </header>

  {#if !report}
    <ZipDropzone
      label="仅支持 Kelivo v1.2.0 备份 zip 文件"
      onFile={handleFile}
    />
  {/if}

  {#if processing}
    <div class="text-center py-6 text-sm text-blue-600 font-medium">
      正在解析 SQLite 快照并转换数据，请稍候…
    </div>
  {/if}

  {#if error}
    <div class="p-4 bg-red-50 border-l-4 border-red-500 rounded text-sm text-red-800">
      <p class="font-semibold">处理失败</p>
      <p class="mt-1 break-all">{error}</p>
    </div>
  {/if}

  {#if report}
    <section class="bg-white border border-gray-200 rounded-xl shadow-sm overflow-hidden">
      <div class="px-6 py-4 border-b border-gray-100 flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 class="font-bold text-gray-900">兼容结果</h2>
          <p class="text-xs text-gray-400 mt-0.5">
            {report.source.fileName} · {report.source.format} v{report.source.formatVersion}
            {report.source.appVersion ? ` · 源应用 ${report.source.appVersion}` : ''}
          </p>
        </div>
        <div class="flex gap-2">
          <button
            class="bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
            onclick={downloadCompat}
          >下载兼容包</button>
          <button
            class="bg-gray-100 hover:bg-gray-200 text-gray-700 text-sm font-medium px-4 py-2 rounded-lg transition-colors"
            onclick={() => downloadText(compatReportToMarkdown(report!), `${outputName.replace(/\.zip$/, '')}_兼容报告.md`, 'text/markdown;charset=utf-8')}
          >下载兼容报告</button>
        </div>
      </div>

      <div class="px-6 py-4 grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.conversations}</div>
          <div class="text-xs text-gray-500 mt-1">会话</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.messages}</div>
          <div class="text-xs text-gray-500 mt-1">消息</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.toolEvents}</div>
          <div class="text-xs text-gray-500 mt-1">工具事件</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.assistants}</div>
          <div class="text-xs text-gray-500 mt-1">助手</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.memories}</div>
          <div class="text-xs text-gray-500 mt-1">记忆</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.mediaFiles}</div>
          <div class="text-xs text-gray-500 mt-1">媒体文件</div>
        </div>
        <div class="bg-gray-50 rounded-lg p-3">
          <div class="text-2xl font-bold text-gray-900">{report.totals.geminiSignatures}</div>
          <div class="text-xs text-gray-500 mt-1">Gemini 签名</div>
        </div>
      </div>

      {#if report.warnings.length > 0}
        <div class="px-6 py-3 border-t border-gray-100">
          <h3 class="text-sm font-semibold text-amber-700 mb-2">警告</h3>
          <ul class="space-y-1 text-xs text-amber-800 list-disc pl-4">
            {#each report.warnings as w}<li class="break-all">{w}</li>{/each}
          </ul>
        </div>
      {/if}

      {#if report.dropped.length > 0}
        <div class="px-6 py-3 border-t border-gray-100">
          <h3 class="text-sm font-semibold text-gray-900 mb-2">丢弃项</h3>
          <ul class="space-y-1 text-xs text-gray-600 list-disc pl-4">
            {#each report.dropped as d}
              <li>
                {d.category}：{d.count}
                {#if d.detail}
                  <span class="text-gray-400">（{d.detail.join('，')}）</span>
                {/if}
              </li>
            {/each}
          </ul>
        </div>
      {/if}

      <div class="px-6 py-3 border-t border-gray-100 flex gap-4">
        <button
          class="text-sm text-blue-600 hover:text-blue-700 font-medium"
          onclick={() => {
            report = null;
            resultZip = null;
          }}
        >重新上传</button>
      </div>
    </section>
  {/if}
</div>
