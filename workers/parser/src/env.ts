/** Bindings of sroka-parser (keep in sync with wrangler.jsonc). */
export interface ParserEnv {
  // RPC-typed stub: import the LibraryDO type from workers/api only as a type if needed.
  LIBRARY: DurableObjectNamespace;
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
