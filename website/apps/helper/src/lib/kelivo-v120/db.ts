/**
 * Kelivo v1.2.0 database/kelivo.db 只读封装（官方 sqlite-wasm）
 *
 * 快照特征：备份时为一致快照（journal_mode=DELETE、无 WAL 侧车），
 * 直接 posix_create_file + 只读打开即可；失败时内存 deserialize 兜底。
 */

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
    SQLITE_DESERIALIZE_FREEONCLOSE: number;
  };
  wasm: {
    allocFromTypedArray: (data: Uint8Array) => unknown;
  };
  oo1: {
    DB: new (filename: string, flags: string) => DbInstance;
  };
}

interface DbInstance {
  exec(sql: string, options?: { rowMode?: string; callback?: (row: Record<string, unknown>) => void | false }): void;
  close(): void;
  pointer: unknown;
}

type InitModuleFn = (opts?: { print?: (m: string) => void; printErr?: (m: string) => void }) => Promise<Sqlite3Module>;

export interface KelivoDb {
  queryAll<T = Record<string, unknown>>(sql: string): T[];
  queryOne<T = Record<string, unknown>>(sql: string): T | null;
  close(): void;
}

let sqlite3Promise: Promise<Sqlite3Module> | null = null;

function initSqlite(): Promise<Sqlite3Module> {
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

let runCounter = 0;

export interface OpenResult {
  db: KelivoDb;
  memoryFallback: boolean;
  diagnostics: string | null;
}

function wrapDb(db: DbInstance): KelivoDb {
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
    close: () => {
      try {
        db.close();
      } catch {
        /* 已关闭 */
      }
    },
  };
}

export async function openKelivoDb(dbBytes: Uint8Array): Promise<OpenResult> {
  const sqlite3 = await initSqlite();
  const capi = sqlite3.capi;
  const wasm = sqlite3.wasm;

  runCounter++;
  const dbPath = `/kh_${Date.now()}_${runCounter}_kelivo.db`;
  const bytes =
    dbBytes.byteOffset === 0 && dbBytes.byteLength === dbBytes.buffer.byteLength
      ? dbBytes
      : dbBytes.slice();

  let fsError: string | null = null;
  try {
    capi.sqlite3_js_posix_create_file(dbPath, bytes);
    const db = new sqlite3.oo1.DB(dbPath, 'r');
    return { db: wrapDb(db), memoryFallback: false, diagnostics: null };
  } catch (e) {
    fsError = e instanceof Error ? e.message : String(e);
  }

  try {
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
      diagnostics: `VFS 打开失败（${fsError ?? 'n/a'}）`,
    };
  } catch (e) {
    throw new Error(
      `database/kelivo.db 无法打开：FS=${fsError ?? 'n/a'}；deserialize=${e instanceof Error ? e.message : String(e)}`,
    );
  }
}
