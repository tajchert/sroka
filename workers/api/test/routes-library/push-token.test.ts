import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { LibraryDO } from "../../src/library-do.ts";
import { makeApp } from "./app.ts";

const DEV = { "x-sroka-device": "and_0192f3c4-1111-7000-8000-0000000000aa" };

describe("PUT/DELETE /v1/push-token", () => {
  it("requires a real device header", async () => {
    const { call } = makeApp();
    const body = { platform: "fcm", token: "t" };
    const cases: Record<string, string>[] = [{}, { "x-sroka-device": "rest" }, { "x-sroka-device": "bad id!" }];
    for (const headers of cases) {
      const r = await call("PUT", "/v1/push-token", body, headers);
      expect(r.status).toBe(400);
      expect(r.json).toEqual({ error: "validation", message: "device header required" });
      expect((await call("DELETE", "/v1/push-token", undefined, headers)).json).toEqual({ error: "validation", message: "device header required" });
    }
  });

  it("validates the body", async () => {
    const { call } = makeApp();
    for (const body of [
      "not json",
      { platform: "fcm" },
      { platform: "apns", token: "abcd" },
      { platform: "apns", token: "xyz", apnsEnvironment: "sandbox", apnsTopic: "app.sroka" },
      { platform: "apns", token: "abcd", apnsEnvironment: "sandbox", apnsTopic: "com.evil" },
    ]) {
      const r = await call("PUT", "/v1/push-token", body, DEV);
      expect(r.status, JSON.stringify(body)).toBe(400);
      expect(r.json.error).toBe("invalid_request");
    }
  });

  it("stores, replaces and deletes this device's token (204, idempotent)", async () => {
    const { call, env, user } = makeApp();
    const lib = env.LIBRARY.getByName(user);
    const rows = () =>
      runInDurableObject(lib, (_i: LibraryDO, s) => s.storage.sql.exec("SELECT device_id, platform, token, apns_env, apns_topic FROM push_devices").toArray());

    expect((await call("PUT", "/v1/push-token", { platform: "fcm", token: "tok-1" }, DEV)).status).toBe(204);
    expect((await call("PUT", "/v1/push-token", { platform: "fcm", token: "tok-2" }, DEV)).status).toBe(204);
    expect(await rows()).toEqual([{ device_id: DEV["x-sroka-device"], platform: "fcm", token: "tok-2", apns_env: null, apns_topic: null }]);

    const ios = { "x-sroka-device": "ios_0192f3c4-1111-7000-8000-0000000000bb" };
    const r = await call("PUT", "/v1/push-token", { platform: "apns", token: "a1b2c3", apnsEnvironment: "production", apnsTopic: "app.sroka" }, ios);
    expect(r.status).toBe(204);
    expect(await rows()).toHaveLength(2);

    expect((await call("DELETE", "/v1/push-token", undefined, DEV)).status).toBe(204);
    expect((await call("DELETE", "/v1/push-token", undefined, DEV)).status).toBe(204);
    expect(await rows()).toEqual([{ device_id: ios["x-sroka-device"], platform: "apns", token: "a1b2c3", apns_env: "production", apns_topic: "app.sroka" }]);
  });
});
