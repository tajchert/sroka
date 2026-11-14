import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index.ts";
import type { Env } from "../src/env.ts";

async function call(req: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env as unknown as Env, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

const ID = "0192f3c4-1111-7000-8000-0000000000aa";

// One route per mounted /v1 family (account, items, tags, sync, imports, exports, admin).
const PROTECTED: [string, string][] = [
  ["GET", "/v1/me"],
  ["GET", "/v1/items"],
  ["GET", `/v1/items/${ID}`],
  ["GET", "/v1/tags"],
  ["GET", "/v1/sync/pull"],
  ["POST", "/v1/sync/push"],
  ["GET", "/v1/imports/0192f3c4-1111-7000-8000-0000000000bb"],
  ["GET", "/v1/exports?format=json"],
  ["GET", "/v1/admin/site-rules"],
  ["GET", "/v1/admin/parse/summary"],
];

describe("auth wildcard middleware", () => {
  it.each(PROTECTED)("%s %s without a session answers 401", async (method, path) => {
    const init: RequestInit = { method };
    if (method === "POST") {
      init.headers = { "content-type": "application/json" };
      init.body = "{}";
    }
    const res = await call(new Request(`http://localhost:8787${path}`, init));
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
  });

  it.each(["/v1/health", "/v1/config"])("public route %s stays public", async (path) => {
    const res = await call(new Request(`http://localhost:8787${path}`));
    expect(res.status).toBe(200);
  });
});
