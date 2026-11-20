import { beforeEach, describe, expect, it } from "vitest";
import { APNS_BODY } from "../../src/push/apns.ts";
import { fcmMessage } from "../../src/push/fcm.ts";
import { type PushDevice, PushSender, resetPushState } from "../../src/push/index.ts";
import { ecKey, fakeFetch, json, serviceAccount, verifyJwt, withOauth } from "./helpers.ts";

beforeEach(() => resetPushState());

const fcmDevice = (token = "fcm-token-1"): PushDevice => ({ deviceId: "and_1", platform: "fcm", token, apnsEnv: null, apnsTopic: null });
const apnsDevice = (env: "sandbox" | "production" = "sandbox", token = "abcdef0123"): PushDevice => ({
  deviceId: "ios_1",
  platform: "apns",
  token,
  apnsEnv: env,
  apnsTopic: "app.sroka.dev",
});

async function apnsConfig() {
  const k = await ecKey();
  return { cfg: { APNS_KEY: k.pem, APNS_KEY_ID: "KEY1234567", APNS_TEAM_ID: "TEAM123456" }, publicKey: k.publicKey };
}

describe("FCM sender", () => {
  it("exchanges a signed service-account JWT, sends a data-only message, caches the access token", async () => {
    const { json: saJson, sa, publicKey } = await serviceAccount();
    let now = 1_800_000_000_000;
    const f = fakeFetch(withOauth(() => json(200, { name: "projects/sroka-95489/messages/1" })));
    const sender = new PushSender({ FCM_SERVICE_ACCOUNT: saJson }, f.fetch, () => now);

    const r = await sender.send([fcmDevice()]);
    expect(r).toMatchObject({ fcm: 1, apns: 0, pruned: 0, failed: 0, skipped: 0 });
    expect(f.calls.map((c) => c.url)).toEqual(["https://oauth2.googleapis.com/token", "https://fcm.googleapis.com/v1/projects/sroka-95489/messages:send"]);

    const oauth = f.calls[0]!;
    expect(oauth.method).toBe("POST");
    expect(oauth.headers["content-type"]).toBe("application/x-www-form-urlencoded");
    const form = new URLSearchParams(oauth.body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const jwt = await verifyJwt(form.get("assertion")!, publicKey);
    expect(jwt.valid).toBe(true);
    expect(jwt.header).toEqual({ alg: "RS256", typ: "JWT" });
    expect(jwt.claims).toEqual({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now / 1000,
      exp: now / 1000 + 3600,
    });

    const send = f.calls[1]!;
    expect(send.method).toBe("POST");
    expect(send.headers.authorization).toBe("Bearer access-1");
    expect(send.headers["content-type"]).toBe("application/json");
    expect(JSON.parse(send.body)).toEqual({
      message: { token: "fcm-token-1", data: { type: "sync" }, android: { priority: "HIGH", collapse_key: "sync", ttl: "43200s" } },
    });
    expect(JSON.parse(send.body)).toEqual(fcmMessage("fcm-token-1"));

    // Cached until exp - 5 min.
    now += 50 * 60 * 1000;
    await sender.send([fcmDevice()]);
    expect(f.calls.filter((c) => c.url.includes("oauth2")).length).toBe(1);
    now += 6 * 60 * 1000;
    await sender.send([fcmDevice()]);
    expect(f.calls.filter((c) => c.url.includes("oauth2")).length).toBe(2);
  });

  it("prunes dead tokens, keeps transient failures", async () => {
    const { json: saJson } = await serviceAccount();
    const responses: Record<string, () => Response> = {
      gone: () => json(404, { error: { code: 404, status: "NOT_FOUND", message: "Requested entity was not found." } }),
      unreg: () =>
        json(400, {
          error: { code: 400, status: "INVALID_ARGUMENT", message: "x", details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "UNREGISTERED" }] },
        }),
      bad: () => json(400, { error: { code: 400, status: "INVALID_ARGUMENT", message: "The registration token is not a valid FCM registration token" } }),
      quota: () => json(429, { error: { code: 429, status: "RESOURCE_EXHAUSTED", details: [{ errorCode: "QUOTA_EXCEEDED" }] } }),
      down: () => json(503, { error: { code: 503, status: "UNAVAILABLE" } }),
    };
    const f = fakeFetch(
      withOauth((c) => {
        const tok = (JSON.parse(c.body) as { message: { token: string } }).message.token;
        if (tok === "net") throw new TypeError("network");
        return responses[tok]!();
      }),
    );
    const sender = new PushSender({ FCM_SERVICE_ACCOUNT: saJson }, f.fetch);
    const r = await sender.send(["gone", "unreg", "bad", "quota", "down", "net"].map((t) => ({ ...fcmDevice(t), deviceId: `and_${t}` })));
    expect(r.outcomes.map((o) => o.outcome.status)).toEqual(["prune", "prune", "prune", "failed", "failed", "failed"]);
    expect(r).toMatchObject({ fcm: 0, pruned: 3, failed: 3 });
    // No retries: one send per device (+1 oauth).
    expect(f.calls.length).toBe(7);
  });

  it("an OAuth failure fails the sends without throwing", async () => {
    const { json: saJson } = await serviceAccount();
    const f = fakeFetch(() => json(400, { error: "invalid_grant" }));
    const r = await new PushSender({ FCM_SERVICE_ACCOUNT: saJson }, f.fetch).send([fcmDevice()]);
    expect(r).toMatchObject({ failed: 1, pruned: 0 });
    expect(f.calls.length).toBe(1);
  });
});

describe("APNs sender", () => {
  it("sends a background push with an ES256 provider token, reused across sends", async () => {
    const { cfg, publicKey } = await apnsConfig();
    const now = 1_800_000_000_000;
    const f = fakeFetch(() => new Response(null, { status: 200 }));
    const sender = new PushSender(cfg, f.fetch, () => now);
    expect(await sender.send([apnsDevice("sandbox")])).toMatchObject({ apns: 1, fcm: 0 });
    await sender.send([apnsDevice("production")]);
    const [a, b] = f.calls as [(typeof f.calls)[0], (typeof f.calls)[0]];
    expect(a.url).toBe("https://api.sandbox.push.apple.com/3/device/abcdef0123");
    expect(b.url).toBe("https://api.push.apple.com/3/device/abcdef0123");
    expect(a.method).toBe("POST");
    expect(a.headers).toMatchObject({
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-topic": "app.sroka.dev",
      "apns-collapse-id": "sync",
      "apns-expiration": String(now / 1000 + 43200),
    });
    expect(JSON.parse(a.body)).toEqual({ aps: { "content-available": 1 }, type: "sync" });
    expect(a.body).toBe(APNS_BODY);
    const auth = a.headers.authorization!;
    expect(auth.startsWith("bearer ")).toBe(true);
    const jwt = await verifyJwt(auth.slice(7), publicKey);
    expect(jwt.valid).toBe(true);
    expect(jwt.header).toEqual({ alg: "ES256", typ: "JWT", kid: "KEY1234567" });
    expect(jwt.claims).toEqual({ iss: "TEAM123456", iat: now / 1000 });
    expect(b.headers.authorization).toBe(auth);
  });

  it("410 prunes; 429/5xx/network fail without retry", async () => {
    const { cfg } = await apnsConfig();
    const byToken: Record<string, () => Response> = {
      aa: () => json(410, { reason: "Unregistered", timestamp: 1 }),
      bb: () => json(429, { reason: "TooManyRequests" }),
      cc: () => json(500, { reason: "InternalServerError" }),
    };
    const f = fakeFetch((c) => {
      const tok = c.url.split("/").pop()!;
      if (tok === "dd") throw new TypeError("network");
      return byToken[tok]!();
    });
    const r = await new PushSender(cfg, f.fetch).send(["aa", "bb", "cc", "dd"].map((t) => ({ ...apnsDevice("production", t), deviceId: `ios_${t}` })));
    expect(r.outcomes.map((o) => o.outcome)).toEqual([
      { status: "prune", reason: "Unregistered" },
      { status: "failed", reason: "TooManyRequests" },
      { status: "failed", reason: "InternalServerError" },
      { status: "failed", reason: "network" },
    ]);
    expect(f.calls.length).toBe(4);
  });

  it("BadDeviceToken retries once on the other environment: success reports it, failure prunes", async () => {
    const { cfg } = await apnsConfig();
    const ok = fakeFetch((c) => (c.url.startsWith("https://api.sandbox.") ? json(400, { reason: "BadDeviceToken" }) : new Response(null, { status: 200 })));
    const r = await new PushSender(cfg, ok.fetch).send([apnsDevice("sandbox")]);
    expect(r.outcomes[0]!.outcome).toEqual({ status: "sent", apnsEnv: "production" });
    expect(r.apns).toBe(1);
    expect(ok.calls.map((c) => c.url)).toEqual(["https://api.sandbox.push.apple.com/3/device/abcdef0123", "https://api.push.apple.com/3/device/abcdef0123"]);

    const bad = fakeFetch(() => json(400, { reason: "BadDeviceToken" }));
    const r2 = await new PushSender(cfg, bad.fetch).send([apnsDevice("production")]);
    expect(r2.outcomes[0]!.outcome.status).toBe("prune");
    expect(bad.calls.length).toBe(2);

    // A transient error on the retry keeps the row.
    const flaky = fakeFetch((c) => (c.url.startsWith("https://api.push.") ? json(400, { reason: "BadDeviceToken" }) : json(503, { reason: "ServiceUnavailable" })));
    const r3 = await new PushSender(cfg, flaky.fetch).send([apnsDevice("production")]);
    expect(r3.outcomes[0]!.outcome.status).toBe("failed");
  });
});

describe("PushSender without credentials", () => {
  it("skips every platform and never fetches", async () => {
    const f = fakeFetch(() => {
      throw new Error("must not fetch");
    });
    const r = await new PushSender({}, f.fetch).send([fcmDevice(), apnsDevice()]);
    expect(r).toMatchObject({ fcm: 0, apns: 0, pruned: 0, failed: 0, skipped: 2 });
    expect(f.calls).toEqual([]);
    // Incomplete APNs credentials count as missing; a malformed service account too.
    const r2 = await new PushSender({ APNS_KEY: "x", APNS_KEY_ID: "k", FCM_SERVICE_ACCOUNT: "{not json" }, f.fetch).send([fcmDevice(), apnsDevice()]);
    expect(r2.skipped).toBe(2);
    expect(f.calls).toEqual([]);
  });
});
