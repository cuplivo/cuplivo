/**
 * RikkaHub SQLite 读取封装（官方 sqlite-wasm，WAL 完整回放）
 *
 * 打开策略（分层兜底）：
 * 1. 主路径：db+wal 字节 → sqlite3_js_posix_create_file 写入 VFS → 以 'w'（读写）打开。
 *    必须用读写模式：WAL 库打开需要创建 -shm（共享内存缓存），只读模式在 shm 缺失时返回 CANTOPEN。
 * 2. 兜底：FS 打开失败 → sqlite3_deserialize 内存注入（WAL 无法回放，仅主库内容）。
 * 路径每次运行唯一，避免残留文件干扰。
 */

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
  /** true = 以内存 deserialize 兜底打开（WAL 未回放） */
  memoryFallback: boolean;
  /** 打开失败详情（诊断用） */
  diagnostics: string | null;
}

export async function openRikkaHubDb(files: RikkaHubDbFile): Promise<OpenResult> {
  const sqlite3 = await initSqlite();
  const capi = sqlite3.capi;
  const wasm = sqlite3.wasm;

  runCounter++;
  const dbPath = `/kh_${Date.now()}_${runCounter}_${files.dbName}`;

  const tryFsOpen = (): Database | null => {
    try {
      capi.sqlite3_js_posix_create_file(dbPath, files.dbBytes);
      if (files.walBytes) {
        capi.sqlite3_js_posix_create_file(`${dbPath}-wal`, files.walBytes);
      }
      // 'w' = 读写：WAL 库需要创建 -shm，只读会 CANTOPEN
      return new sqlite3.oo1.DB(dbPath, 'w');
    } catch (e) {
      return null;
    }
  };

  const wrapDb = (db: Database): RikkaHubDb => {
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
  };

  // 1. FS 主路径
  const fsDb = tryFsOpen();
  if (fsDb) {
    return { db: wrapDb(fsDb), memoryFallback: false, diagnostics: null };
  }

  // 2. 兜底：内存 deserialize（无法回放 WAL）
  let memoryFallback = false;
  let diagnostics: string | null = null;
  try {
    diagnostics = `VFS 打开失败（可用 VFS: ${capi.sqlite3_js_vfs_list().join(', ')}）`;
    const db = new sqlite3.oo1.DB(':memory:', 'c');
    const ptr = wasm.allocFromTypedArray(files.dbBytes);
    const rc = capi.sqlite3_deserialize(
      db.pointer,
      'main',
      ptr,
      files.dbBytes.length,
      files.dbBytes.length,
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
    memoryFallback = true;
    return { db: wrapDb(db), memoryFallback, diagnostics };
  } catch (e) {
    throw new Error(
      `rikka_hub.db 无法打开：${diagnostics ?? ''} ${e instanceof Error ? e.message : String(e)}`,
    );
  }
}
