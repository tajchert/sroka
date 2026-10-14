import type { ParseResult } from "@sroka/shared";

/** The slice of LibraryDO's RPC surface the parser uses (the class lives in workers/api). */
export interface LibraryParserRpc {
  markParsed(itemId: string, result: ParseResult): Promise<{ ok: boolean }>;
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
