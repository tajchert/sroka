import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { listPushDevices } from "../../src/do/push-store.ts";
import { APP, call, json, signIn, testEnv } from "./helpers.ts";

const PHONE_A = "0193a5b0-0000-7000-8000-00000000000a";
const PHONE_B = "0193a5b0-0000-7000-8000-00000000000b";

async function userId(token: string): Promise<string> {
  const res = await call("/v1/me", { headers: { authorization: `Bearer ${token}` } });
  expect(res.status).toBe(200);
  return ((await res.json()) as { user: { id: string } }).user.id;
}

async function register(token: string, device: string, fcm: string): Promise<void> {
  const res = await call("/v1/push-token", {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "x-sroka-device": device, "content-type": "application/json", origin: APP },
    body: JSON.stringify({ platform: "fcm", token: fcm }),
  });
  expect(res.status).toBe(204);
}

async function devices(uid: string): Promise<string[]> {
  return runInDurableObject(testEnv.LIBRARY.getByName(uid), (_inst, state) => listPushDevices(state.storage).map((d) => d.deviceId));
}

async function signOut(token: string, headers: Record<string, string> = {}): Promise<Response> {
  return call("/api/auth/sign-out", json({}, { authorization: `Bearer ${token}`, ...headers }));
}

describe("sign-out push-token backstop", () => {
  it("removes only this device's push row and still signs out", async () => {
    const { token } = await signIn("signout-push-1@example.com");
    const uid = await userId(token);
    await register(token, PHONE_A, "fcm-a");
    await register(token, PHONE_B, "fcm-b");

    const res = await signOut(token, { "x-sroka-device": PHONE_A });
    expect(res.status).toBe(200);
    expect(await devices(uid)).toEqual([PHONE_B]);
    expect((await call("/v1/me", { headers: { authorization: `Bearer ${token}` } })).status).toBe(401);
  });

  it("without a device header (or with the REST id) is a no-op for push rows", async () => {
    const first = await signIn("signout-push-2@example.com");
    const uid = await userId(first.token);
    await register(first.token, PHONE_A, "fcm-a2");

    expect((await signOut(first.token)).status).toBe(200);
    expect(await devices(uid)).toEqual([PHONE_A]);

    const second = await signIn("signout-push-2@example.com");
    expect((await signOut(second.token, { "x-sroka-device": "rest" })).status).toBe(200);
    expect(await devices(uid)).toEqual([PHONE_A]);
  });

  it("an unauthenticated sign-out with a device header touches nothing", async () => {
    const { token } = await signIn("signout-push-3@example.com");
    const uid = await userId(token);
    await register(token, PHONE_A, "fcm-a3");

    await call("/api/auth/sign-out", json({}, { "x-sroka-device": PHONE_A }));
    expect(await devices(uid)).toEqual([PHONE_A]);
  });
});
