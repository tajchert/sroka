import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ALARM,
  backoffMs,
  clearFailed,
  enqueue,
  MAX_QUEUE_AGE,
  MAX_QUEUE_LENGTH,
  MAX_QUEUED_HTML,
  MIN_ATTEMPTS_BEFORE_EXPIRY,
  processQueue,
  QueueFullError,
  readFailed,
  readQueue,
  releaseQueue,
  removeQueuedUrl,
} from "./queue.ts";
import { saveWithFallback } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes, requestJson } from "./test-chrome.ts";

let c: ReturnType<typeof installChrome>;
beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  await setSettings({ token: "t", signedOut: false });
});
const ok = () => jsonRes(202, { item: { id: "i1" }, created: true });

describe("backoff", () => {
  it("doubles from 30s, caps at 1h, honours Retry-After", () => {
    expect(backoffMs(1)).toBe(30_000);
    expect(backoffMs(2)).toBe(60_000);
    expect(backoffMs(20)).toBe(3_600_000);
    expect(backoffMs(1, 120)).toBe(120_000);
  });
});

describe("retry queue", () => {
  it("enqueues, strips oversized html, schedules alarm", async () => {
    await enqueue({ url: "https://a.com/", html: "x".repeat(MAX_QUEUED_HTML + 1) });
    const q = await readQueue();
    expect(q).toHaveLength(1);
    expect(q[0]!.body.html).toBeUndefined();
    expect(c.alarms.create).toHaveBeenCalledWith(ALARM, expect.any(Object));
  });

  it("sends due entries and clears queue + alarm", async () => {
    await enqueue({ url: "https://a.com/" });
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => ok());
    expect(await processQueue()).toEqual({ sent: 1, remaining: 0 });
    expect(c.alarms.clear).toHaveBeenCalledWith(ALARM);
  });

  it("network failure keeps entry with backoff", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    expect(await processQueue(now)).toEqual({ sent: 0, remaining: 1 });
    const [e] = await readQueue();
    expect(e!.attempts).toBe(1);
    expect(e!.nextAt).toBe(now + 30_000);
    // not due yet → no fetch
    const f = vi.spyOn(globalThis, "fetch");
    f.mockClear();
    await processQueue(now + 1000);
    expect(f).not.toHaveBeenCalled();
  });

  it("401 never drops queued saves and stops the run", async () => {
    await enqueue({ url: "https://a.com/" });
    await enqueue({ url: "https://b.com/" });
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(401, { error: "unauthorized" }));
    expect(await processQueue()).toMatchObject({ sent: 0, remaining: 2 });
    expect(f).toHaveBeenCalledTimes(1);
    expect(c.storage.local.data.signedOut).toBe(true);
    // after sign-in, release and send
    await setSettings({ token: "new", signedOut: false });
    await releaseQueue();
    f.mockImplementation(async () => ok());
    expect(await processQueue()).toEqual({ sent: 2, remaining: 0 });
  });

  it("413 retries without html; permanent 400 drops", async () => {
    await enqueue({ url: "https://a.com/", html: "<p>x</p>" });
    await enqueue({ url: "bad" });
    const bodies: string[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (_u, init) => {
      const b = await requestJson(init as RequestInit);
      bodies.push(JSON.stringify(b));
      if (b.url === "bad") return jsonRes(400, { error: "invalid_url" });
      return b.html ? jsonRes(413, { error: "payload_too_large" }) : ok();
    });
    await processQueue();
    const r = await processQueue();
    expect(r.remaining).toBe(0);
    expect(bodies.some((b) => b.includes('"html"'))).toBe(true);
  });
});

describe("saveWithFallback", () => {
  it("queues on offline and on 401, drops nothing", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new TypeError("x"));
    expect(await saveWithFallback({ url: "https://a.com/" })).toMatchObject({ ok: false, queued: true, reason: "offline" });
    f.mockResolvedValueOnce(jsonRes(401, { error: "unauthorized" }));
    expect(await saveWithFallback({ url: "https://b.com/" })).toMatchObject({ queued: true, reason: "signed_out" });
    expect(await readQueue()).toHaveLength(2);
  });

  it("does not queue permanent errors", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonRes(400, { error: "invalid_url" }));
    expect(await saveWithFallback({ url: "https://a.com/" })).toMatchObject({ ok: false, queued: false });
    expect(await readQueue()).toHaveLength(0);
  });

  it("413 with html retries url-only", async () => {
    const f = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonRes(413, { error: "payload_too_large" }))
      .mockResolvedValueOnce(ok());
    const r = await saveWithFallback({ url: "https://a.com/", html: "<p/>" });
    expect(r.ok).toBe(true);
    expect((await requestJson(f.mock.calls[1]![1] as RequestInit)).html).toBeUndefined();
  });
});

describe("review fixes", () => {
  it("quota failure on enqueue retries without html", async () => {
    const real = c.storage.local.set.getMockImplementation()!;
    c.storage.local.set.mockImplementationOnce(async () => {
      throw new Error("QUOTA_BYTES quota exceeded");
    });
    c.storage.local.set.mockImplementation(real);
    await enqueue({ url: "https://a.com/", html: "<p>hi</p>" });
    const q = await readQueue();
    expect(q).toHaveLength(1);
    expect(q[0]!.body.html).toBeUndefined();
  });

  it("caps total queued html in bytes", async () => {
    const big = "é".repeat(400_000); // 800 KB
    for (let i = 0; i < 7; i++) await enqueue({ url: `https://a.com/${i}`, html: big });
    const withHtml = (await readQueue()).filter((e) => e.body.html).length;
    expect(withHtml).toBe(5);
  });

  it("never drops network failures; records permanent failures", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    let t = now;
    for (let i = 0; i < 60; i++) {
      await processQueue(t);
      t += 3_600_000;
    }
    expect(await readQueue()).toHaveLength(1);
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => jsonRes(400, { error: "invalid_url" }));
    await processQueue(t);
    expect(await readQueue()).toHaveLength(0);
    expect((await readFailed())[0]!.url).toBe("https://a.com/");
  });

  it("400 retries without title", async () => {
    const f = vi.spyOn(globalThis, "fetch");
    f.mockImplementationOnce(async () => jsonRes(400, { error: "invalid_request" }));
    f.mockImplementation(async () => ok());
    const r = await saveWithFallback({ url: "https://a.com/", title: "t" });
    expect(r.ok).toBe(true);
    expect(JSON.parse(f.mock.calls[1]![1]!.body as string).title).toBeUndefined();
  });

  it("signed-out processQueue is a no-op and clears the alarm", async () => {
    await enqueue({ url: "https://a.com/" });
    await setSettings({ signedOut: true });
    const f = vi.spyOn(globalThis, "fetch");
    f.mockClear();
    expect(await processQueue()).toEqual({ sent: 0, remaining: 1 });
    expect(f).not.toHaveBeenCalled();
    expect(c.alarms.clear).toHaveBeenCalledWith(ALARM);
  });

  it("removeQueuedUrl drops only that url", async () => {
    await enqueue({ url: "https://a.com/" });
    await enqueue({ url: "https://b.com/" });
    await removeQueuedUrl("https://a.com/");
    expect((await readQueue()).map((e) => e.body.url)).toEqual(["https://b.com/"]);
  });
});

describe("queue bounds", () => {
  const offline = () => vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));

  it("gives up on a retryable save only after MAX_QUEUE_AGE and enough attempts, and records it", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    offline();
    // Retried hourly for 7 days: kept.
    let t = now;
    while (t < now + MAX_QUEUE_AGE) {
      await processQueue(t);
      t += 3_600_000;
    }
    expect(await readQueue()).toHaveLength(1);
    t += 1; // now strictly older than MAX_QUEUE_AGE
    await processQueue(t);
    expect(await readQueue()).toHaveLength(0);
    expect(await readFailed()).toEqual([{ url: "https://a.com/", reason: "expired", at: t }]);
  });

  it("an old entry that was barely tried (browser closed) gets its attempts first", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    offline();
    let t = now + MAX_QUEUE_AGE + 1;
    for (let i = 1; i < MIN_ATTEMPTS_BEFORE_EXPIRY; i++) {
      await processQueue(t);
      t += 3_600_000;
    }
    expect((await readQueue())[0]!.attempts).toBe(MIN_ATTEMPTS_BEFORE_EXPIRY - 1);
    await processQueue(t);
    expect(await readQueue()).toHaveLength(0);
    expect((await readFailed())[0]!.reason).toBe("expired");
  });

  it("entries waiting for sign-in never expire", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    await setSettings({ signedOut: true });
    await processQueue(now + 30 * MAX_QUEUE_AGE);
    expect(await readQueue()).toHaveLength(1);
    expect(await readFailed()).toEqual([]);
  });

  it("refuses new saves beyond MAX_QUEUE_LENGTH, visibly, keeping the queued ones", async () => {
    const full = Array.from({ length: MAX_QUEUE_LENGTH }, (_, i) => ({ id: `q${i}`, body: { url: `https://a.com/${i}` }, attempts: 0, nextAt: 0, addedAt: 0 }));
    c.storage.local.data.queue = full;
    await expect(enqueue({ url: "https://new.com/" })).rejects.toBeInstanceOf(QueueFullError);
    expect(await readQueue()).toHaveLength(MAX_QUEUE_LENGTH);
    expect((await readFailed()).at(-1)).toMatchObject({ url: "https://new.com/", reason: "queue_full" });
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    expect(await saveWithFallback({ url: "https://new2.com/" })).toMatchObject({ ok: false, queued: false, reason: "error", message: expect.stringContaining("Too many saves") });
  });

  it("clearFailed dismisses the record", async () => {
    c.storage.local.data.failedSaves = [{ url: "https://a.com/", reason: "expired", at: 1 }];
    await clearFailed();
    expect(await readFailed()).toEqual([]);
  });
});

describe("queue ownership", () => {
  it("never sends one account's queued captures with another account's session or to another server", async () => {
    await setSettings({ token: "ta", email: "A@example.com", signedOut: false, serverUrl: "https://api.sroka.app" });
    await enqueue({ url: "https://intranet.example/", html: "<p>secret</p>" });
    // A signs out; B signs in on the same browser.
    await setSettings({ token: "tb", email: "b@example.com", signedOut: false });
    const f = vi.spyOn(globalThis, "fetch").mockImplementation(async () => ok());
    expect(await processQueue()).toEqual({ sent: 0, remaining: 1 });
    expect(f).not.toHaveBeenCalled();
    // Same account, different server: still not sent.
    await setSettings({ token: "ta2", email: "a@example.com", serverUrl: "https://evil.example" });
    expect(await processQueue()).toEqual({ sent: 0, remaining: 1 });
    expect(f).not.toHaveBeenCalled();
    // Back on A's server as A: sent.
    await setSettings({ serverUrl: "https://api.sroka.app" });
    expect(await processQueue()).toEqual({ sent: 1, remaining: 0 });
  });
});

describe("unexpected errors", () => {
  const portal = () => new Response("<html>login</html>", { status: 200, headers: { "content-type": "text/html" } });

  it("a 200 with a non-JSON body keeps the entry, backs off and re-arms the alarm", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    c.alarms.create.mockClear();
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => portal());
    await expect(processQueue(now)).resolves.toEqual({ sent: 0, remaining: 1 });
    const [e] = await readQueue();
    expect(e!.attempts).toBe(1);
    expect(e!.nextAt).toBe(now + 30_000);
    expect(c.alarms.create).toHaveBeenCalledWith(ALARM, expect.any(Object));
  });

  it("an error that is not an ApiFailure is handled like a network failure", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    c.alarms.create.mockClear();
    const broken = { status: 200, get ok(): boolean { throw new RangeError("boom") } } as unknown as Response;
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => broken);
    await expect(processQueue(now)).resolves.toEqual({ sent: 0, remaining: 1 });
    const [e] = await readQueue();
    expect(e!.attempts).toBe(1);
    expect(e!.nextAt).toBe(now + 30_000);
    expect(c.alarms.create).toHaveBeenCalledWith(ALARM, expect.any(Object));
  });

  it("an unexpected error on one entry does not stop the pass or lose its progress", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    await enqueue({ url: "https://b.com/" }, now);
    let n = 0;
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => (n++ === 0 ? portal() : ok()));
    await expect(processQueue(now)).resolves.toEqual({ sent: 1, remaining: 1 });
    const q = await readQueue();
    expect(q).toHaveLength(1);
    expect(q[0]!.body.url).toBe("https://a.com/");
  });

  it("an unexpected error still expires under the normal bounds", async () => {
    const now = 1_000_000;
    await enqueue({ url: "https://a.com/" }, now);
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => portal());
    let t = now;
    while (t < now + MAX_QUEUE_AGE) {
      await processQueue(t);
      t += 3_600_000;
    }
    expect(await readQueue()).toHaveLength(1);
    t += 1;
    await processQueue(t);
    expect(await readQueue()).toHaveLength(0);
    expect(await readFailed()).toEqual([{ url: "https://a.com/", reason: "expired", at: t }]);
  });
});
