<script lang="ts">
  let { onFile, label, hint, accept }: {
    onFile: (file: File) => void;
    label?: string;
    hint?: string;
    accept?: string;
  } = $props();

  let dragging = $state(false);
  let inputEl: HTMLInputElement;

  function handleFiles(files: FileList | null) {
    const f = files?.[0];
    if (f) onFile(f);
  }

  function onDrop(e: DragEvent) {
    e.preventDefault();
    dragging = false;
    handleFiles(e.dataTransfer?.files ?? null);
  }
</script>

<div
  class="border-2 border-dashed rounded-xl p-10 text-center cursor-pointer transition-colors {dragging
    ? 'border-blue-500 bg-blue-50/50'
    : 'border-gray-300 hover:border-blue-400 hover:bg-gray-50/50'}"
  role="button"
  tabindex="0"
  ondragover={(e) => {
    e.preventDefault();
    dragging = true;
  }}
  ondragleave={() => (dragging = false)}
  ondrop={onDrop}
  onclick={() => inputEl?.click()}
  onkeydown={(e) => {
    if (e.key === 'Enter' || e.key === ' ') inputEl?.click();
  }}
>
  <input
    bind:this={inputEl}
    type="file"
    accept={accept ?? '.zip'}
    class="hidden"
    onchange={(e) => handleFiles(e.currentTarget.files)}
  />
  <div class="text-sm text-gray-600">
    <span class="font-medium text-blue-600">点击选择</span> 或拖拽文件到此处
    {#if label}<p class="mt-1 text-gray-500">{label}</p>{/if}
    {#if hint}<p class="mt-1 text-xs text-gray-400">{hint}</p>{/if}
  </div>
</div>
