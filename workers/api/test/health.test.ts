import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index.ts";
import type { Env } from "../src/env.ts";

describe("sroka-api smoke", () => {
  it("GET /v1/health", async () => {
    const ctx = createExecutionContext();
    const res = await worker.fetch(new Request("http://localhost:8787/v1/health"), env as unknown as Env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });
});
