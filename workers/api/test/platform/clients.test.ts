import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { call, signIn, testEnv } from "./helpers.ts";
import { clientKind, resetSeenClients } from "../../src/clients.ts";

type Me = { clients?: { extension: boolean; android: boolean } };
const me = async (token: string, headers: Record<string, string> = {}) =>
  (await (await call("/v1/me", { headers: { authorization: `Bearer ${token}`, ...headers } })).json()) as Me;

describe("clientKind", () => {
  it("detects extension and android, nothing else", () => {
    expect(clientKind(new Headers({ "x-sroka-device": "ext-123" }))).toBe("extension");
    expect(clientKind(new Headers({ "user-agent": "Sroka-Android/1.2.3", "x-sroka-device": "abc" }))).toBe("android");
    expect(clientKind(new Headers({ "user-agent": "Mozilla/5.0", "x-sroka-device": "web-1" }))).toBeNull();
    expect(clientKind(new Headers())).toBeNull();
  });
});

describe("/v1/me clients", () => {
  it("starts all-false and flips once each client type calls", async () => {
    resetSeenClients();
    const { token } = await signIn("clients@example.com");
    expect((await me(token)).clients).toEqual({ extension: false, android: false });

    // The requesting client counts immediately, even on its first call.
    expect((await me(token, { "x-sroka-device": "ext-abc" })).clients).toEqual({ extension: true, android: false });
    expect((await me(token)).clients).toEqual({ extension: true, android: false });

    // Any authenticated /v1 route records it, not only /v1/me.
    const res = await call("/v1/tags", { headers: { authorization: `Bearer ${token}`, "user-agent": "Sroka-Android/0.9" } });
    expect(res.status).toBe(200);
    expect((await me(token)).clients).toEqual({ extension: true, android: true });
  });

  it("is write-once and per user", async () => {
    resetSeenClients();
    const a = await signIn("clients-a@example.com");
    const b = await signIn("clients-b@example.com");
    await me(a.token, { "x-sroka-device": "ext-1" });
    const stub = testEnv.LIBRARY.getByName((await userId(a.token))!);
    const first = await runInStorage(stub);
    expect(typeof first).toBe("number");
    await new Promise((r) => setTimeout(r, 5));
    resetSeenClients();
    await me(a.token, { "x-sroka-device": "ext-1" });
    expect(await runInStorage(stub)).toBe(first);
    expect((await me(b.token)).clients).toEqual({ extension: false, android: false });
  });

  it("unauthenticated requests record nothing", async () => {
    const res = await call("/v1/me", { headers: { "x-sroka-device": "ext-1" } });
    expect(res.status).toBe(401);
  });
});

async function userId(token: string): Promise<string | undefined> {
  const r = (await (await call("/v1/me", { headers: { authorization: `Bearer ${token}` } })).json()) as { user: { id: string } };
  return r.user.id;
}

function runInStorage(stub: ReturnType<typeof testEnv.LIBRARY.getByName>): Promise<number | undefined> {
  return runInDurableObject(stub, (_i: unknown, state) => state.storage.get<number>("client:extension"));
}
