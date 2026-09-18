/**
 * RikkaHub SQLite 读取封装（官方 sqlite-wasm）
 *
 * 打开策略：
 * 1. 纯 JS 将 WAL 已提交帧合入主库，并把 journal 头改为 DELETE（见 wal.ts）。
 *    sqlite-wasm 无 xShmMap，无法直接打开 WAL 模式库（会 SQLITE_CANTOPEN）。
 * 2. 主路径：prepared bytes → sqlite3_js_posix_create_file → 只读打开。
 * 3. 兜底：FS 打开失败 → sqlite3_deserialize 内存注入。
 * 路径每次运行唯一，避免残留文件干扰。
 */

import { prepareRikkaHubDbBytes } from './wal';

// 包未导出命名类型，用结构化类型定义所需 API 面
interface Sqlite3Module {
  capi: {
    sqlite3_js_posix_create_file: (filename: string, data: Uint8Array, dataLen?: number) => void;
    sqlite3_deserialize: (
      db: unknown,
      schema: string | number | null,
      data: unknown,
      szDb: number,
      szBuf: number,
      flags: number,
    ) => number;
    sqlite3_js_vfs_list: () => string[];
    SQLITE_DESERIALIZE_FREEONCLOSE: number;
  };
  wasm: {
    allocFromTypedArray: (data: Uint8Array) => unknown;
    fs?: { removeFile?: (path: string) => void };
  };
  oo1: {
    DB: new (filename: string, flags: string) => Database;
  };
}

interface Database {
  exec(sql: string, options?: { rowMode?: string; callback?: (row: Record<string, unknown>) => void | false }): void;
  close(): void;
  pointer: unknown;
}

type InitModuleFn = (opts?: { print?: (m: string) => void; printErr?: (m: string) => void }) => Promise<Sqlite3Module>;

let sqlite3Promise: Promise<Sqlite3Module> | null = null;
let runCounter = 0;

export function initSqlite(): Promise<Sqlite3Module> {
  if (!sqlite3Promise) {
    sqlite3Promise = (async () => {
      const mod = (await import('@sqlite.org/sqlite-wasm')) as unknown as {
        default: InitModuleFn;
      };
      return mod.default({ print: () => {}, printErr: () => {} });
    })();
  }
  return sqlite3Promise;
}

export interface RikkaHubDbFile {
  /** zip 内的原始文件名（如 'rikka_hub.db'） */
  dbName: string;
  dbBytes: Uint8Array;
  walBytes: Uint8Array | null;
}

export interface RikkaHubDb {
  /** 查询所有行，每行一个对象（列名小写） */
  queryAll<T = Record<string, unknown>>(sql: string): T[];
  /** 查询单行 */
  queryOne<T = Record<string, unknown>>(sql: string): T | null;
  /** 执行语句 */
  exec(sql: string): void;
  close(): void;
}

export interface OpenResult {
  db: RikkaHubDb;
  /** true = 以内存 deserialize 兜底打开 */
  memoryFallback: boolean;
  /** 是否合入了至少 1 个已提交 WAL frame */
  walReplayed: boolean;
  /** WAL 回放降级原因（仍可能成功打开主库） */
  walDegraded: string | null;
  /** 打开路径诊断 */
  diagnostics: string | null;
}

function wrapDb(db: Database): RikkaHubDb {
  const queryAll = <T = Record<string, unknown>>(sql: string): T[] => {
    const rows: T[] = [];
    db.exec(sql, {
      rowMode: 'object',
      callback: (row) => {
        rows.push(row as T);
      },
    });
    return rows;
  };
  return {
    queryAll,
    queryOne: <T = Record<string, unknown>>(sql: string): T | null => {
      const rows = queryAll<T>(sql);
      return rows.length > 0 ? rows[0] : null;
    },
    exec: (sql: string) => db.exec(sql),
    close: () => {
      try {
        db.close();
      } catch {
        /* 已关闭 */
      }
    },
  };
}

export async function openRikkaHubDb(files: RikkaHubDbFile): Promise<OpenResult> {
  const sqlite3 = await initSqlite();
  const capi = sqlite3.capi;
  const wasm = sqlite3.wasm;

  const prepared = prepareRikkaHubDbBytes(files.dbBytes, files.walBytes);
  const walReplayed = prepared.walFramesApplied > 0;
  const walDegraded = prepared.degradedReason;

  runCounter++;
  const dbPath = `/kh_${Date.now()}_${runCounter}_rikka.db`;

  let fsError: string | null = null;
  try {
    // 确保传入完整 buffer 视图（部分 wasm 绑定不接受 SharedArrayBuffer 视图）
    const bytes =
      prepared.bytes.byteOffset === 0 && prepared.bytes.byteLength === prepared.bytes.buffer.byteLength
        ? prepared.bytes
        : prepared.bytes.slice();
    capi.sqlite3_js_posix_create_file(dbPath, bytes);
    const db = new sqlite3.oo1.DB(dbPath, 'r');
    return {
      db: wrapDb(db),
      memoryFallback: false,
      walReplayed,
      walDegraded,
      diagnostics: null,
    };
  } catch (e) {
    fsError = e instanceof Error ? e.message : String(e);
  }

  // 兜底：内存 deserialize
  try {
    const bytes =
      prepared.bytes.byteOffset === 0 && prepared.bytes.byteLength === prepared.bytes.buffer.byteLength
        ? prepared.bytes
        : prepared.bytes.slice();
    const db = new sqlite3.oo1.DB(':memory:', 'c');
    const ptr = wasm.allocFromTypedArray(bytes);
    const rc = capi.sqlite3_deserialize(
      db.pointer,
      'main',
      ptr,
      bytes.length,
      bytes.length,
      capi.SQLITE_DESERIALIZE_FREEONCLOSE,
    );
    if (rc !== 0) {
      try {
        db.close();
      } catch {
        /* 忽略 */
      }
      throw new Error(`sqlite3_deserialize 失败 (rc=${rc})`);
    }
    return {
      db: wrapDb(db),
      memoryFallback: true,
      walReplayed,
      walDegraded,
      diagnostics: `VFS 打开失败（${fsError}；可用 VFS: ${capi.sqlite3_js_vfs_list().join(', ')}）`,
    };
  } catch (e) {
    throw new Error(
      `rikka_hub.db 无法打开：FS=${fsError ?? 'n/a'}；deserialize=${e instanceof Error ? e.message : String(e)}`,
    );
  }
}
