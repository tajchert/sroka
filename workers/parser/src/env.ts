import type { ParseResult } from "@sroka/shared";

/** The slice of LibraryDO's RPC surface the parser uses (the class lives in workers/api). */
export interface LibraryParserRpc {
  markParsed(itemId: string, result: ParseResult): Promise<{ ok: boolean }>;
  /** False when the job is superseded / already done / the item or library is gone. */
  parseWanted(itemId: string, parseGen: number): Promise<boolean>;
  /** GC backfill: re-emits the library's public content refs to D1 `content_refs`; pending > 0 = flush failed. */
  reemitContentRefs(): Promise<{ refs: number; pending: number }>;
}

/** `env.LIBRARY` as the parser sees it: only getByName() is used. */
export interface LibraryNamespace {
  getByName(name: string): LibraryParserRpc;
}

/** Bindings of sroka-parser (keep in sync with wrangler.jsonc). */
export interface ParserEnv {
  LIBRARY: LibraryNamespace;
  DB: D1Database;
  CONTENT: R2Bucket;
  CONFIG: KVNamespace;
  IMAGES: ImagesBinding;
  ENVIRONMENT: "development" | "production";
  APP_ORIGIN: string;
  API_ORIGIN: string;
  CONTENT_ORIGIN: string;
  BROWSER_RENDER_ENABLED: string;
}
