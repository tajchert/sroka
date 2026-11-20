import { runInDurableObject } from "cloudflare:test";
import { PARSER_VERSION, type ParseResult, type PushTokenRequest, uuidv7 } from "@sroka/shared";
import { beforeEach, describe, expect, it } from "vitest";
import type { LibraryDO } from "../../src/library-do.ts";
import { PushSender, resetPushState } from "../../src/push/index.ts";
import { ecKey, fakeFetch, json, serviceAccount, withOauth } from "../push/helpers.ts";
import { T0, add, freshLibrary } from "./helpers.ts";

beforeEach(() => resetPushState());

const DAY = 24 * 60 * 60 * 1000;
const fcm = (token: string): PushTokenRequest => ({ platform: "fcm", token });
const apns = (token: string, env: "sandbox" | "production" = "sandbox"): PushTokenRequest => ({
  platform: "apns",
  token,
  apnsEnvironment: env,
  apnsTopic: "app.sroka.dev",
});

function ok(parseGen = 1, over: Partial<ParseResult> = {}): ParseResult {
  return {
    status: "ok",
    parseGen,
    contentId: uuidv7(),
    contentPrivate: false,
    title: "T",
    excerpt: "E",
    siteName: "S",
    author: null,
    lang: "en",
    wordCount: 100,
    readingMinutes: 1,
    parserVersion: PARSER_VERSION,
    ...over,
  };
}

type Lib = ReturnType<typeof freshLibrary>["lib"];

const rows = (lib: Lib) =>
  runInDurableObject(lib, (_i: LibraryDO, state) =>
    state.storage.sql.exec("SELECT device_id, platform, token, apns_env, apns_topic, updated_at FROM push_devices ORDER BY device_id").toArray(),
  );
const meta = (lib: Lib, k: string) =>
  runInDurableObject(lib, (_i: LibraryDO, state) => Number(state.storage.sql.exec("SELECT v FROM meta WHERE k = ?", k).toArray()[0]?.v ?? 0));
const setMeta = (lib: Lib, k: string, v: number) =>
  runInDurableObject(lib, (_i: LibraryDO, state) => {
    state.storage.sql.exec("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v);
  });
const alarmAt = (lib: Lib) => runInDurableObject(lib, (_i: LibraryDO, state) => state.storage.getAlarm());

/** Installs a PushSender with test credentials and a recording fake fetch into the DO instance. */
async function installSender(lib: Lib, respond?: Parameters<typeof fakeFetch>[0]) {
  const sa = await serviceAccount();
  const k = await ecKey();
  const f = fakeFetch(respond ?? withOauth(() => json(200, { name: "m" })));
  const sender = new PushSender({ FCM_SERVICE_ACCOUNT: sa.json, APNS_KEY: k.pem, APNS_KEY_ID: "K", APNS_TEAM_ID: "T" }, f.fetch);
  await runInDurableObject(lib, (inst: LibraryDO) => {
    (inst as unknown as { pusher: PushSender }).pusher = sender;
  });
  return f;
}

/** Adds n items (parse gen 1). */
async function addItems(lib: Lib, n: number, tag = "x"): Promise<string[]> {
  const ids = Array.from({ length: n }, () => uuidv7());
  await lib.applyOps(
    "d",
    ids.map((id, i) => add(id, `https://push-${tag}-${i}.example/`, T0 + i)),
  );
  return ids;
}

describe("push_devices", () => {
  it("upserts by device id, drops the same token under another device, caps at 10", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("t1"), 1000);
    await lib.putPushToken("and_a", fcm("t2"), 2000);
    expect(await rows(lib)).toEqual([{ device_id: "and_a", platform: "fcm", token: "t2", apns_env: null, apns_topic: null, updated_at: 2000 }]);

    await lib.putPushToken("ios_b", apns("abcd"), 3000);
    // Same token re-registered under a new device id (reinstall): the old row goes.
    await lib.putPushToken("ios_c", apns("abcd", "production"), 4000);
    expect((await rows(lib)).map((r) => [r.device_id, r.token, r.apns_env, r.apns_topic])).toEqual([
      ["and_a", "t2", null, null],
      ["ios_c", "abcd", "production", "app.sroka.dev"],
    ]);

    for (let i = 0; i < 10; i++) await lib.putPushToken(`and_n${i}`, fcm(`n${i}`), 5000 + i);
    const r = await rows(lib);
    expect(r).toHaveLength(10);
    // The two least recently updated rows were dropped.
    expect(r.map((x) => x.device_id)).not.toContain("and_a");
    expect(r.map((x) => x.device_id)).not.toContain("ios_c");
  });

  it("delete is idempotent", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("t1"), 1);
    await lib.deletePushToken("and_a");
    await lib.deletePushToken("and_a");
    await lib.deletePushToken("never");
    expect(await rows(lib)).toEqual([]);
  });

  it("destroy wipes the tokens", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("t1"), 1);
    await lib.destroy();
    const tables = await runInDurableObject(lib, (_i: LibraryDO, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE name = 'push_devices'").toArray(),
    );
    expect(tables).toEqual([]);
  });
});

describe("coalesced sync push", () => {
  it("several markParsed → one alarm-driven send per device; failed results don't trigger", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("ftok"), 1);
    await lib.putPushToken("ios_b", apns("abcd"), 2);
    const f = await installSender(lib);
    const ids = await addItems(lib, 4);

    expect(await lib.markParsed(ids[0]!, { ...ok(), status: "failed", contentId: undefined, error: "http_404" } as ParseResult)).toEqual({ ok: true });
    expect(await meta(lib, "push_due_at")).toBe(0);

    const before = Date.now();
    for (const id of ids.slice(1)) expect(await lib.markParsed(id, ok())).toEqual({ ok: true });
    const due = await meta(lib, "push_due_at");
    expect(due).toBeGreaterThanOrEqual(before + 10_000);
    expect(due).toBeLessThan(Date.now() + 11_000);
    expect(await alarmAt(lib)).toBe(due);
    expect(f.calls).toEqual([]); // nothing sent before the alarm

    // Fire the alarm as if the due time had come.
    await setMeta(lib, "push_due_at", Date.now() - 1);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    const sends = f.calls.filter((c) => !c.url.includes("oauth2"));
    expect(sends.map((c) => c.url).sort()).toEqual(["https://api.sandbox.push.apple.com/3/device/abcd", "https://fcm.googleapis.com/v1/projects/sroka-95489/messages:send"]);
    expect(await meta(lib, "push_due_at")).toBe(0);
    const sentAt = await meta(lib, "push_last_sent_at");
    expect(sentAt).toBeGreaterThan(0);

    // A second firing without new content sends nothing.
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(f.calls.filter((c) => !c.url.includes("oauth2"))).toHaveLength(2);

    // Next content within the minute: due no earlier than lastSent + 60 s.
    const more = await addItems(lib, 1, "y");
    await lib.markParsed(more[0]!, ok());
    expect(await meta(lib, "push_due_at")).toBe(sentAt + 60_000);
  });

  it("no registered devices → no pending push", async () => {
    const { lib } = freshLibrary("push");
    const [id] = await addItems(lib, 1);
    await lib.markParsed(id!, ok());
    expect(await meta(lib, "push_due_at")).toBe(0);
  });

  it("a push firing keeps the daily maintenance alarm; maintenance is not run early", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("ftok"), 1);
    const f = await installSender(lib);
    await addItems(lib, 1); // ensureAlarm → maint_due_at ≈ now + 1 day
    const maint = await meta(lib, "maint_due_at");
    expect(maint).toBeGreaterThan(Date.now() + DAY - 60_000);
    expect(await alarmAt(lib)).toBe(maint);

    await setMeta(lib, "push_due_at", Date.now() - 1);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(f.calls.some((c) => c.url.includes("fcm.googleapis.com"))).toBe(true);
    expect(await meta(lib, "maint_due_at")).toBe(maint); // maintenance didn't run
    expect(await alarmAt(lib)).toBe(maint); // re-armed at the daily time

    // A pending push later than now but earlier than maintenance → the alarm is the push.
    const later = Date.now() + 30_000;
    await setMeta(lib, "push_due_at", later);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm()); // early wake-up: nothing due
    expect(await alarmAt(lib)).toBe(later);
    expect(await meta(lib, "push_due_at")).toBe(later);

    // Maintenance due (legacy libraries have no maint_due_at) → runs and re-arms one day out, push stays pending.
    await setMeta(lib, "maint_due_at", 0);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(await meta(lib, "maint_due_at")).toBeGreaterThan(Date.now() + DAY - 60_000);
    expect(await alarmAt(lib)).toBe(later);
  });

  it("prunes dead tokens and stores the APNs environment that worked", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_dead", fcm("dead"), 1);
    await lib.putPushToken("ios_swap", apns("abcd", "sandbox"), 2);
    await lib.putPushToken("ios_gone", apns("ef01", "production"), 3);
    await installSender(
      lib,
      withOauth((c) => {
        if (c.url.includes("fcm.googleapis.com")) return json(404, { error: { status: "NOT_FOUND" } });
        if (c.url.endsWith("/ef01")) return json(410, { reason: "Unregistered" });
        return c.url.startsWith("https://api.sandbox.") ? json(400, { reason: "BadDeviceToken" }) : new Response(null, { status: 200 });
      }),
    );
    const [id] = await addItems(lib, 1);
    await lib.markParsed(id!, ok());
    await setMeta(lib, "push_due_at", Date.now() - 1);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect((await rows(lib)).map((r) => [r.device_id, r.apns_env])).toEqual([["ios_swap", "production"]]);
  });

  it("without credentials nothing is fetched and rows are kept", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("ftok"), 1);
    const f = fakeFetch(() => {
      throw new Error("must not fetch");
    });
    await runInDurableObject(lib, (inst: LibraryDO) => {
      (inst as unknown as { pusher: PushSender }).pusher = new PushSender({}, f.fetch);
    });
    const [id] = await addItems(lib, 1);
    await lib.markParsed(id!, ok());
    await setMeta(lib, "push_due_at", Date.now() - 1);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(f.calls).toEqual([]);
    expect(await rows(lib)).toHaveLength(1);
    expect(await meta(lib, "push_due_at")).toBe(0);
  });
});
