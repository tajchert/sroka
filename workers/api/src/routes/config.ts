import { Hono } from "hono";
import { LIMITS, type ConfigResponse } from "@sroka/shared";
import type { AppEnv } from "../env.ts";

export const configRoutes = new Hono<AppEnv>();

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function merge<T>(base: T, over: unknown): T {
  if (!isObj(base) || !isObj(over)) return base;
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(over)) {
    out[k] = isObj(out[k]) && isObj(v) ? merge(out[k], v) : v;
  }
  return out as T;
}

export function defaultConfig(appOrigin: string): ConfigResponse {
  return {
    appOrigin,
    minVersions: { android: null, ios: null, extension: null },
    features: { imports: true, exports: true, browserRender: false, highlights: false, realtime: false },
    limits: { maxOpsPerPush: LIMITS.maxOpsPerPush, maxHtmlBytes: LIMITS.maxHtmlBytes, maxImportBytes: LIMITS.maxImportBytes },
  };
}

/** GET /v1/config — no auth. KV "config" merged over defaults; appOrigin always from env. */
configRoutes.get("/config", async (c) => {
  let kv: unknown = null;
  try {
    kv = await c.env.CONFIG.get("config", "json");
  } catch (e) {
    console.error("[sroka] CONFIG read failed", e);
  }
  const cfg = merge(defaultConfig(c.env.APP_ORIGIN), kv);
  cfg.appOrigin = c.env.APP_ORIGIN;
  return c.json(cfg, 200, { "Cache-Control": "public, max-age=300" });
});
