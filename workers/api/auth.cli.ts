// Stub for `npm run auth:schema` (Better Auth CLI needs an exported `auth`).
import { createAuth } from "./src/auth.ts";
import type { Env } from "./src/env.ts";

export const auth = createAuth({
  DB: {} as D1Database,
  BETTER_AUTH_SECRET: "x".repeat(32),
  APP_ORIGIN: "http://localhost:8787",
  API_ORIGIN: "http://localhost:8787",
  ENVIRONMENT: "development",
} as unknown as Env);
