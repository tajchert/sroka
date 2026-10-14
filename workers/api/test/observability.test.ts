import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.ts";
import type { AppEnv, Env } from "../src/env.ts";
import { onError, requestLogger } from "../src/middleware/logging.ts";
import { resetClientErrorLimiter } from "../src/routes/client-errors.ts";

const E = env as unknown as Env;

async function call(req: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, E, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

afterEach(() => vi.restoreAllMocks());

describe("onError", () => {
  it("returns 500 JSON with the cf-ray as requestId and logs a structured error", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    const app = new Hono<AppEnv>();
    app.use("*", requestLogger);
    app.get("/v1/boom", () => {
      throw new Error("kaboom jane@example.com");
    });
    app.onError(onError);
    const res = await app.request("/v1/boom", { headers: { "cf-ray": "abc123-WAW" } }, E);
    expect(res.status).toBe(500);
    expect(await res.json()).toEqual({ error: "internal", requestId: "abc123-WAW" });
    expect(res.headers.get("x-request-id")).toBe("abc123-WAW");
    const lines = errSpy.mock.calls.map((c) => JSON.parse(c[0] as string));
    const line = lines.find((l) => l.event === "unhandled_error");
    expect(line).toMatchObject({ level: "error", requestId: "abc123-WAW", route: "/v1/boom", errName: "Error" });
    expect(line.stack).toBeTypeOf("string");
    expect(JSON.stringify(line)).not.toContain("jane@");
    expect(lines.some((l) => l.event === "http_request" && l.status === 500)).toBe(true);
  });
});

describe("POST /v1/client-errors", () => {
  beforeEach(() => resetClientErrorLimiter());
  const post = (body: unknown, raw?: string) =>
    call(new Request("http://localhost:8787/v1/client-errors", { method: "POST", headers: { "content-type": "application/json" }, body: raw ?? JSON.stringify(body) }));

  it("accepts a valid report, truncates the stack and logs client_error", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await post({ message: "TypeError: x is undefined", stack: "s".repeat(10_000), url: "/app/item/1", userAgent: "ua", release: "r1" });
    expect(res.status).toBe(204);
    const line = errSpy.mock.calls.map((c) => JSON.parse(c[0] as string)).find((l) => l.event === "client_error");
    expect(line).toMatchObject({ level: "error", clientMessage: "TypeError: x is undefined", clientPath: "/app/item/1", release: "r1" });
    expect(line.clientStack.length).toBeLessThanOrEqual(2100); // logger caps strings
  });

  it("rejects invalid bodies", async () => {
    expect((await post({})).status).toBe(400);
    expect((await post({ message: "" })).status).toBe(400);
    expect((await post(null, "not json")).status).toBe(400);
  });

  it("rejects oversized bodies and rate limits", async () => {
    expect((await post({ message: "x".repeat(20_000) })).status).toBe(413);
    resetClientErrorLimiter();
    vi.spyOn(console, "error").mockImplementation(() => {});
    let last = 0;
    for (let i = 0; i < 12; i++) last = (await post({ message: "m" })).status;
    expect(last).toBe(429);
  });
});
