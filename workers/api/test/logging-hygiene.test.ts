import { afterEach, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import { env } from "cloudflare:workers";
import type { AppEnv, Env } from "../src/env.ts";
import { maskPath, onError, requestLogger } from "../src/middleware/logging.ts";
import { checkTurnstile } from "../src/turnstile.ts";

afterEach(() => vi.restoreAllMocks());

const SIG = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde";
const UID = "usr_Secret-User-Id01";
const CID = "0192f3c4-1111-4000-8000-0000000000aa";

describe("maskPath", () => {
  it("masks exp, signature, user scope and content id of a content-route path", () => {
    const p = maskPath(`/s/1799999999/${SIG}/u.${UID}/${CID}/article.html`);
    expect(p).not.toContain(SIG);
    expect(p).not.toContain(UID);
    expect(p).not.toContain(CID);
    expect(p).toBe("/s/:exp/:sig/:scope/:id/:file");
  });
  it("still masks UUIDs on other paths", () => {
    expect(maskPath(`/v1/items/${CID}`)).toBe("/v1/items/:id");
  });
});

describe("onError path", () => {
  it("does not log the signature or user id of a content path", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
    const app = new Hono<AppEnv>();
    app.use("*", requestLogger);
    app.get("/s/*", () => {
      throw new Error("boom");
    });
    app.onError(onError);
    await app.request(`/s/1799999999/${SIG}/u.${UID}/${CID}/article.html`, {}, env as unknown as Env);
    const out = JSON.stringify(errSpy.mock.calls);
    expect(out).toContain("unhandled_error");
    expect(out).not.toContain(SIG);
    expect(out).not.toContain(UID);
  });
});

describe("turnstile logging", () => {
  it("logs a structured event, not console text, when siteverify is unreachable", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.fn(async () => {
      throw new Error("down");
    });
    const e = { APP_ORIGIN: "https://sroka.app", ENVIRONMENT: "production" as const, TURNSTILE_SECRET_KEY: "s" };
    const req = new Request("https://api.sroka.app/api/auth/x", { method: "POST", headers: { origin: "https://sroka.app", "x-turnstile-token": "t" } });
    expect(await checkTurnstile(e as never, req, f)).toBe("verify_unavailable");
    const line = JSON.parse(errSpy.mock.calls[0]![0] as string);
    expect(line).toMatchObject({ level: "error", event: "turnstile_verify_failed" });
  });
});
