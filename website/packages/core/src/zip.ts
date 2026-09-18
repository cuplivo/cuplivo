/** zip 处理 helpers */
import JSZip from 'jszip';

export async function loadZip(file: File | ArrayBuffer | Uint8Array): Promise<JSZip> {
  return JSZip.loadAsync(file);
}

export async function readZipText(zip: JSZip, path: string): Promise<string | null> {
  const entry = zip.file(path);
  if (!entry) return null;
  return entry.async('string');
}

export async function readZipBytes(zip: JSZip, path: string): Promise<Uint8Array | null> {
  const entry = zip.file(path);
  if (!entry) return null;
  return entry.async('uint8array');
}

/** zip 内所有文件名 */
export function zipPaths(zip: JSZip): string[] {
  return Object.keys(zip.files);
}

/** 在 zip 中按 basename 查找文件路径（用于媒体引用定位） */
export function findFileByBasename(zip: JSZip, name: string): string | null {
  const candidates: string[] = [];
  for (const [path, entry] of Object.entries(zip.files)) {
    if (entry.dir) continue;
    if (path.endsWith(`/${name}`) || path === name) candidates.push(path);
  }
  if (candidates.length === 0) return null;
  // 优先 upload/ 前缀
  return (
    candidates.find((c) => c.startsWith('upload/')) ??
    candidates.find((c) => c.startsWith('fonts/')) ??
    candidates[0]
  );
}

/** 下载 blob */
export function downloadBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

/** 下载纯文本文件 */
export function downloadText(text: string, fileName: string, mime = 'text/plain;charset=utf-8'): void {
  downloadBlob(new Blob([text], { type: mime }), fileName);
}

/** 由源文件名生成输出文件名 */
export function outputNameFrom(sourceName: string, suffix: string): string {
  const base = sourceName.replace(/\.zip$/i, '');
  return `${base}_${suffix}.zip`;
}

/** 复制 zip 中的目录（含子路径）到输出 zip；返回复制的文件数 */
export async function copyZipDir(src: JSZip, dst: JSZip, prefix: string): Promise<number> {
  let count = 0;
  for (const [path, entry] of Object.entries(src.files)) {
    if (entry.dir) continue;
    if (!path.startsWith(prefix)) continue;
    const bytes = await entry.async('uint8array');
    dst.file(path, bytes);
    count++;
  }
  return count;
}
