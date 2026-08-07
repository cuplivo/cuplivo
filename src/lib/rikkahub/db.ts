/**
 * RikkaHub SQLite 读取封装（官方 sqlite-wasm，WAL 完整回放）
 *
 * 流程：zip 字节 → sqlite3_js_posix_create_file 写入 VFS → 打开（自动回放 -wal）
 * 注意：只创建 db + wal，不创建 shm（SQLite 打开时自动重建，避免陈旧 shm 干扰）
 */

// 包未导出命名类型，用结构化类型定义所需 API 面
interface Sqlite3Module {
  capi: {
    sqlite3_js_posix_create_file: (filename: string, data: Uint8Array, dataLen?: number) => void;
  };
  wasm: {
    fs?: { removeFile?: (path: string) => void };
  };
  oo1: {
    DB: new (filename: string, flags: string) => Database;
  };
}

interface Database {
  exec(sql: string, options?: { rowMode?: string; callback?: (row: Record<string, unknown>) => void | false }): void;
  close(): void;
}

type InitModuleFn = (opts?: { print?: (m: string) => void; printErr?: (m: string) => void }) => Promise<Sqlite3Module>;

let sqlite3Promise: Promise<Sqlite3Module> | null = null;

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

export async function openRikkaHubDb(files: RikkaHubDbFile): Promise<RikkaHubDb> {
  const sqlite3 = await initSqlite();
  const capi = sqlite3.capi;
  const fs = sqlite3.wasm.fs;

  const dbPath = `/${files.dbName}`;
  // 清理同名残留（同会话多次迁移）
  if (fs?.removeFile) {
    try {
      fs.removeFile(dbPath);
    } catch {
      /* 不存在则忽略 */
    }
    try {
      fs.removeFile(`${dbPath}-wal`);
    } catch {
      /* 忽略 */
    }
  }
  capi.sqlite3_js_posix_create_file(dbPath, files.dbBytes);
  if (files.walBytes) {
    capi.sqlite3_js_posix_create_file(`${dbPath}-wal`, files.walBytes);
  }

  const db = new sqlite3.oo1.DB(dbPath, 'r');

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
