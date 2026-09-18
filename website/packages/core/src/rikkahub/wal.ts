/**
 * 纯 JS WAL checkpoint：sqlite-wasm 无 xShmMap，无法直接打开 WAL 模式库。
 * 打开前将已提交 WAL frames 合入主库，并把 journal 头改为 DELETE。
 *
 * WAL 格式：https://www.sqlite.org/fileformat2.html#walformat
 */

export interface PrepareDbResult {
  bytes: Uint8Array;
  /** 成功合入的已提交 frame 数 */
  walFramesApplied: number;
  /** 成功合入的 commit 数 */
  walCommits: number;
  /** 非 null 表示未能完整回放 WAL，仅用主库（可能缺近期数据） */
  degradedReason: string | null;
}

const SQLITE_MAGIC = 'SQLite format 3\0';
const WAL_MAGIC_BE = 0x377f0682;
const WAL_MAGIC_LE = 0x377f0683;

function readU32(dv: DataView, offset: number, littleEndian: boolean): number {
  return dv.getUint32(offset, littleEndian);
}

function writeU32BE(out: Uint8Array, offset: number, value: number): void {
  out[offset] = (value >>> 24) & 0xff;
  out[offset + 1] = (value >>> 16) & 0xff;
  out[offset + 2] = (value >>> 8) & 0xff;
  out[offset + 3] = value & 0xff;
}

function headerPageSize(db: Uint8Array): number {
  const raw = (db[16] << 8) | db[17];
  return raw === 1 ? 65536 : raw;
}

function isWalMode(db: Uint8Array): boolean {
  return db[18] === 2 || db[19] === 2;
}

function forceDeleteJournal(out: Uint8Array): void {
  out[18] = 1;
  out[19] = 1;
  const cc = ((out[24] << 24) | (out[25] << 16) | (out[26] << 8) | out[27]) >>> 0;
  const ncc = (cc + 1) >>> 0;
  writeU32BE(out, 24, ncc);
  // version-valid-for (bytes 92-95) = change counter
  out[92] = out[24];
  out[93] = out[25];
  out[94] = out[26];
  out[95] = out[27];
}

/**
 * SQLite WAL rolling checksum。
 * 字段端序由 magic 决定；校验和字序在 JS（主机 LE）上与 magic 相反：
 * BE magic → 按 LE 读 u32 累加；LE magic → 按 BE 读 u32 累加
 * （对齐 sqlite wal.c 的 nativeCksum 规则）。
 */
function walChecksum(
  s0: number,
  s1: number,
  data: Uint8Array,
  cksumLittleEndian: boolean,
): [number, number] {
  let a = s0 >>> 0;
  let b = s1 >>> 0;
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const n = data.byteLength & ~7;
  for (let i = 0; i < n; i += 8) {
    const x0 = dv.getUint32(i, cksumLittleEndian) >>> 0;
    const x1 = dv.getUint32(i + 4, cksumLittleEndian) >>> 0;
    a = (a + x0 + b) >>> 0;
    b = (b + x1 + a) >>> 0;
  }
  return [a, b];
}

function applyWal(dbBytes: Uint8Array, walBytes: Uint8Array): PrepareDbResult {
  if (walBytes.length < 32) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: 'WAL 文件过短，已忽略',
    };
  }

  const wdv = new DataView(walBytes.buffer, walBytes.byteOffset, walBytes.byteLength);
  const magic = wdv.getUint32(0, false);
  if (magic !== WAL_MAGIC_BE && magic !== WAL_MAGIC_LE) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: `WAL magic 无法识别 (0x${magic.toString(16)})`,
    };
  }

  const fieldLE = magic === WAL_MAGIC_LE;
  const ckLE = magic === WAL_MAGIC_BE;
  const walPageSize = readU32(wdv, 8, fieldLE);
  if (walPageSize === 0 || (walPageSize & (walPageSize - 1)) !== 0) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: `WAL page_size 非法 (${walPageSize})`,
    };
  }

  const salt1h = readU32(wdv, 16, fieldLE);
  const salt2h = readU32(wdv, 20, fieldLE);

  let [cksum0, cksum1] = walChecksum(0, 0, walBytes.subarray(0, 24), ckLE);
  const hdrExpect0 = readU32(wdv, 24, fieldLE);
  const hdrExpect1 = readU32(wdv, 28, fieldLE);
  if (hdrExpect0 !== cksum0 || hdrExpect1 !== cksum1) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: 'WAL header 校验失败，已忽略 WAL',
    };
  }

  const dbPageSize = headerPageSize(dbBytes);
  if (dbPageSize !== walPageSize) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: `WAL page_size(${walPageSize}) 与主库(${dbPageSize}) 不一致`,
    };
  }

  type Frame = { pgno: number; page: Uint8Array };
  let tx: Frame[] = [];
  const committed = new Map<number, Uint8Array>();
  let dbSizePages: number | null = null;
  let commits = 0;
  let framesApplied = 0;
  let badChecksum = 0;
  let off = 32;

  while (off + 24 + walPageSize <= walBytes.length) {
    const pgno = readU32(wdv, off, fieldLE);
    const sizeAfter = readU32(wdv, off + 4, fieldLE);
    const s1 = readU32(wdv, off + 8, fieldLE);
    const s2 = readU32(wdv, off + 12, fieldLE);
    const frameCk0 = readU32(wdv, off + 16, fieldLE);
    const frameCk1 = readU32(wdv, off + 20, fieldLE);

    if (pgno === 0 && s1 === 0 && s2 === 0) break;

    // 过期 salt → 上一轮 WAL 循环残留，跳过（不更新 running checksum）
    if (s1 !== salt1h || s2 !== salt2h) {
      off += 24 + walPageSize;
      continue;
    }

    const page = walBytes.subarray(off + 24, off + 24 + walPageSize);
    const frameCkInput = new Uint8Array(8 + walPageSize);
    frameCkInput.set(walBytes.subarray(off, off + 8), 0);
    frameCkInput.set(page, 8);
    const [ns0, ns1] = walChecksum(cksum0, cksum1, frameCkInput, ckLE);
    if (ns0 !== frameCk0 || ns1 !== frameCk1) {
      badChecksum++;
      tx = [];
      break;
    }
    cksum0 = ns0;
    cksum1 = ns1;

    tx.push({ pgno, page: page.slice() });

    if (sizeAfter > 0) {
      for (const f of tx) committed.set(f.pgno, f.page);
      framesApplied += tx.length;
      dbSizePages = sizeAfter;
      tx = [];
      commits++;
    }

    off += 24 + walPageSize;
  }

  const basePages = Math.floor(dbBytes.length / dbPageSize);
  const outPages = dbSizePages ?? basePages;
  const out = new Uint8Array(outPages * dbPageSize);
  out.set(dbBytes.subarray(0, Math.min(dbBytes.length, out.length)));
  for (const [pgno, page] of committed) {
    if (pgno >= 1 && pgno <= outPages) {
      out.set(page, (pgno - 1) * dbPageSize);
    }
  }
  writeU32BE(out, 28, outPages);
  forceDeleteJournal(out);

  let degradedReason: string | null = null;
  if (commits === 0 && walBytes.length > 32) {
    degradedReason =
      badChecksum > 0
        ? 'WAL 帧校验失败，未合入任何提交'
        : 'WAL 中无与当前 salt 匹配的已提交帧';
  } else if (badChecksum > 0) {
    degradedReason = `WAL 部分帧校验失败，已合入此前 ${commits} 次提交`;
  }

  return {
    bytes: out,
    walFramesApplied: framesApplied,
    walCommits: commits,
    degradedReason,
  };
}

/**
 * 将备份中的 db(+wal) 规范为可被 sqlite-wasm 打开的 DELETE-journal 字节。
 */
export function prepareRikkaHubDbBytes(
  dbBytes: Uint8Array,
  walBytes: Uint8Array | null,
): PrepareDbResult {
  if (dbBytes.length < 100) {
    return {
      bytes: dbBytes,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: '数据库文件过短',
    };
  }

  let magicOk = true;
  for (let i = 0; i < 15; i++) {
    if (dbBytes[i] !== SQLITE_MAGIC.charCodeAt(i)) {
      magicOk = false;
      break;
    }
  }
  if (!magicOk || dbBytes[15] !== 0) {
    return {
      bytes: dbBytes,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: '非 SQLite 数据库文件',
    };
  }

  if (walBytes && walBytes.length > 0 && isWalMode(dbBytes)) {
    return applyWal(dbBytes, walBytes);
  }

  if (isWalMode(dbBytes)) {
    const out = dbBytes.slice();
    forceDeleteJournal(out);
    return {
      bytes: out,
      walFramesApplied: 0,
      walCommits: 0,
      degradedReason: '主库为 WAL 模式但备份未含 rikka_hub-wal，近期未 checkpoint 数据可能缺失',
    };
  }

  return {
    bytes: dbBytes,
    walFramesApplied: 0,
    walCommits: 0,
    degradedReason: null,
  };
}
