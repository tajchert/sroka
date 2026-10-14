import { describe, expect, it } from "vitest";
import { call, migrate, signIn, testEnv, APP } from "./helpers.ts";
import type { Env } from "../../src/env.ts";

function fakeAssets(): Env {
  return {
    ...testEnv,
    ASSETS: {
      fetch: async (req: Request) => {
        const p = new URL(req.url).pathname;
        if (p === "/app/") return new Response("<html>shell</html>", { headers: { "content-type": "text/html" } });
        return new Response("nf", { status: 404 });
      },
    },
  } as unknown as Env;
}

describe("assets fallback", () => {
  it("deep link returns the shell (200) without redirect", async () => {
    const res = await call("/app/some/deep/path", {}, APP, fakeAssets());
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("shell");
  });
  it("does not over-match /apple-touch-icon.png", async () => {
    expect((await call("/apple-touch-icon.png", {}, APP, fakeAssets())).status).toBe(404);
  });
});

describe("account delete verification rows", () => {
  it("only removes the exact identifiers", async () => {
    await migrate();
    const { token } = await signIn("bob@x.com");
    const ins = (id: string, ident: string) =>
      testEnv.DB.prepare(
        "insert into verification (id, identifier, value, expires_at, created_at, updated_at) values (?,?,?,?,?,?)",
      )
        .bind(id, ident, "v", Date.now() + 1e5, Date.now(), Date.now())
        .run();
    await ins("v-other", "sign-in-otp-alice.bob@x.com");
    await ins("v-own", "sign-in-otp-bob@x.com");
    const res = await call("/v1/account", {
      method: "DELETE",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ confirm: "DELETE" }),
    });
    expect(res.status).toBe(200);
    const rows = await testEnv.DB.prepare("select id from verification where id in ('v-other','v-own')").all<{ id: string }>();
    expect(rows.results.map((r) => r.id)).toEqual(["v-other"]);
  });
});
