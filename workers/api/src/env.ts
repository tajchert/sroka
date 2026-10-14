import type { ParseJob } from "@sroka/shared";
import type { LibraryDO } from "./library-do.ts";

/** Bindings of sroka-api (keep in sync with wrangler.jsonc). */
export interface Env {
  DB: D1Database;
  CONTENT: R2Bucket;
  CONFIG: KVNamespace;
  LIBRARY: DurableObjectNamespace<LibraryDO>;
  PARSE_QUEUE: Queue<ParseJob>;
  EMAIL: SendEmail;
  IMAGES: ImagesBinding;
  ASSETS: Fetcher;
  ENVIRONMENT: "development" | "production";
  APP_ORIGIN: string;
  API_ORIGIN: string;
  CONTENT_ORIGIN: string;
  BROWSER_RENDER_ENABLED: string;
  BETTER_AUTH_SECRET: string;
  CONTENT_URL_SIGNING_KEY: string;
  REVIEW_EMAIL?: string;
  REVIEW_OTP?: string;
}
