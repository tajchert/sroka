import { runInDurableObject } from "cloudflare:test";
import { PARSER_VERSION, type ParseResult, type PushTokenRequest, uuidv7 } from "@sroka/shared";
import { beforeEach, describe, expect, it } from "vitest";
import type { LibraryStore } from "../../src/do/store.ts";
import { putPushDevice } from "../../src/do/push-store.ts";
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

describe("review hardening", () => {
  it("APNs tokens are stored lowercase, so casing can't bypass the same-token dedupe", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("ios_b", apns("ABCDEF"), 1);
    await lib.putPushToken("ios_c", apns("abcdef"), 2);
    expect((await rows(lib)).map((r) => [r.device_id, r.token])).toEqual([["ios_c", "abcdef"]]);
  });

  it("a stale provider response doesn't prune or rewrite a registration renewed during the send", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("same"), 1000);
    await lib.putPushToken("ios_b", apns("abcd", "sandbox"), 1000);
    let storage: DurableObjectStorage | null = null;
    await runInDurableObject(lib, (_i: LibraryDO, state) => {
      storage = state.storage;
    });
    await installSender(
      lib,
      withOauth((c) => {
        // The phones re-register (same tokens) while their sends are in flight.
        putPushDevice(storage!, "and_a", fcm("same"), 1000);
        putPushDevice(storage!, "ios_b", apns("abcd", "sandbox"), 1000);
        if (c.url.includes("fcm.googleapis.com")) return json(404, { error: { status: "NOT_FOUND" } });
        return c.url.startsWith("https://api.sandbox.") ? json(400, { reason: "BadDeviceToken" }) : new Response(null, { status: 200 });
      }),
    );
    await setMeta(lib, "push_due_at", Date.now() - 1);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    const r = await rows(lib);
    expect(r.map((x) => [x.device_id, x.apns_env])).toEqual([
      ["and_a", null],
      ["ios_b", "sandbox"],
    ]);
    expect(r.every((x) => Number(x.updated_at) > 1000)).toBe(true); // same-ms re-registration still bumps the revision
  });

  it("a dispatch interrupted mid-send is resent by the next alarm; the 60 s floor counts it", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("ftok"), 1);
    const f = await installSender(lib);
    const started = Date.now() - 5_000;
    await setMeta(lib, "push_sending_at", started); // as left behind by a reset during sendPush
    // Content ready while "sending": due no earlier than the interrupted send + 60 s.
    const [id] = await addItems(lib, 1);
    await lib.markParsed(id!, ok());
    expect(await meta(lib, "push_due_at")).toBe(started + 60_000);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(f.calls.filter((c) => c.url.includes("fcm.googleapis.com"))).toHaveLength(1);
    expect(await meta(lib, "push_sending_at")).toBe(0);
    expect(await meta(lib, "push_due_at")).toBe(started + 60_000); // the newer content still gets its own push
    expect(await alarmAt(lib)).toBe(started + 60_000);
  });

  it("no slack for pushes: an alarm just before the due time doesn't send", async () => {
    const { lib } = freshLibrary("push");
    await lib.putPushToken("and_a", fcm("ftok"), 1);
    const f = await installSender(lib);
    await addItems(lib, 1);
    const due = Date.now() + 500;
    await setMeta(lib, "push_due_at", due);
    await runInDurableObject(lib, (inst: LibraryDO) => inst.alarm());
    expect(f.calls).toEqual([]);
    expect(await alarmAt(lib)).toBe(due);
  });

  it("failed maintenance is retried in 5 minutes, not a day", async () => {
    const { lib } = freshLibrary("push");
    await addItems(lib, 1);
    await setMeta(lib, "maint_due_at", 0);
    await runInDurableObject(lib, async (inst: LibraryDO) => {
      (inst as unknown as { sweepStalePending: () => Promise<number> }).sweepStalePending = async () => {
        throw new Error("queue down");
      };
      await inst.alarm();
    });
    const due = await meta(lib, "maint_due_at");
    expect(due).toBeGreaterThan(Date.now() + 4 * 60_000);
    expect(due).toBeLessThan(Date.now() + 6 * 60_000);
    expect(await alarmAt(lib)).toBe(due);
  });

  it("a failed sweep send leaves the requeued rows due again (parse-gen guarded)", async () => {
    const { lib } = freshLibrary("push");
    const ids = await addItems(lib, 2);
    const stamped = await runInDurableObject(lib, (inst: LibraryDO, state) => {
      const store = (inst as unknown as { store: LibraryStore }).store;
      state.storage.sql.exec("UPDATE items SET parse_requested_at = 1");
      const jobs = store.requeueStalePending(10, 10, 5000);
      // Item 2 got a newer parse request meanwhile: its row must not be touched.
      state.storage.sql.exec("UPDATE items SET parse_gen = parse_gen + 1 WHERE id = ?", ids[1]!);
      store.unmarkRequeued(jobs, 5000);
      return state.storage.sql.exec("SELECT id, parse_requested_at AS t FROM items ORDER BY id").toArray();
    });
    expect(stamped).toEqual([
      { id: ids[0], t: 0 },
      { id: ids[1], t: 5000 },
    ]);
  });

  it("first maintenance schedule on a pre-v7 library keeps a sooner legacy alarm as maintenance", async () => {
    const { lib } = freshLibrary("push");
    await addItems(lib, 1);
    const legacy = Date.now() + 2 * 60_000;
    await runInDurableObject(lib, async (_i: LibraryDO, state) => {
      state.storage.sql.exec("DELETE FROM meta WHERE k = 'maint_due_at'");
      await state.storage.setAlarm(legacy);
    });
    await lib.scheduleParseSweep(); // 31 min out
    expect(await meta(lib, "maint_due_at")).toBe(legacy);
    expect(await alarmAt(lib)).toBe(legacy);
  });
});
