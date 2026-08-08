export function has<T extends object>(obj: T, key: PropertyKey): key is keyof T {
  return key in obj;
}

/** 安全 JSON.parse，失败返回 fallback */
export function tryParse<T>(json: string | null | undefined, fallback: T): T {
  if (json === null || json === undefined || json === '') return fallback;
  try {
    return JSON.parse(json) as T;
  } catch {
    return fallback;
  }
}

/** 安全 JSON.parse，失败/空返回 null（用于"可缺失"场景） */
export function tryParseOrNull<T>(json: string | null | undefined): T | null {
  if (json === null || json === undefined || json === '') return null;
  try {
    return JSON.parse(json) as T;
  } catch {
    return null;
  }
}

/** epoch millis → ISO（无时区后缀的本地形态；工具内仅兜底使用） */
export function isoFromEpochMillis(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3, '0')}`
  );
}

/** 提取文件路径的 basename（兼容 / 与 \） */
export function basename(p: string): string {
  const idx = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return idx >= 0 ? p.slice(idx + 1) : p;
}

/**
 * kotlinx.serialization 多态 type：可能是短名 `Image` 或 FQCN
 * `me.rerere.rikkahub.data.model.Avatar.Image`
 */
export function normalizePolymorphicType(type: string | undefined | null): string {
  if (!type) return '';
  const parts = type.split('.');
  return parts[parts.length - 1] || type;
}

/**
 * 将 Android/iOS 绝对路径或 file:// URI 规范为 zip 内相对路径（优先 upload/）。
 * http(s)/data: 原样返回。
 */
export function toZipLocalPath(
  url: string | null | undefined,
  findInZip: (name: string) => string | null,
): string | null {
  if (url == null || url === '') return null;
  if (isHttpUrl(url) || /^data:/i.test(url)) return url;
  const name = basename(url.replace(/^file:\/\//i, ''));
  if (!name) return url;
  return findInZip(name) ?? (name.includes('.') ? `upload/${name}` : url);
}

/** 判断字符串是否像本地文件路径（相对路径或绝对路径，非 URL / data URI） */
export function isLocalPath(p: string): boolean {
  return !/^(https?:|data:|file:|content:)/i.test(p);
}

export function isRemoteOrDataUri(p: string): boolean {
  return /^(https?:|data:|file:)/i.test(p);
}

export function isHttpUrl(p: string): boolean {
  return /^https?:/i.test(p);
}

/** 通用 mime 兜底 */
export function guessMime(name: string, fallback = 'application/octet-stream'): string {
  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  const map: Record<string, string> = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
    webp: 'image/webp',
    svg: 'image/svg+xml',
    mp4: 'video/mp4',
    webm: 'video/webm',
    mp3: 'audio/mpeg',
    wav: 'audio/wav',
    m4a: 'audio/mp4',
    pdf: 'application/pdf',
    doc: 'application/msword',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    txt: 'text/plain',
    md: 'text/markdown',
    json: 'application/json',
  };
  return map[ext] ?? fallback;
}

/** 组装 Kelivo 内联标记（拆分字面量，避免 Tailwind 误扫描为任意 CSS 值） */
export function marker(type: 'image' | 'file', inner: string): string {
  return `[${type}:${inner}]`;
}

/** 转义标记内 `|` 分隔符字段 */
export function escapeMarkerField(s: string): string {
  return s.replace(/\|/g, '%7C');
}
