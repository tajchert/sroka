import { beforeEach, describe, expect, it, vi } from "vitest";
import { ALARM, backoffMs, enqueue, MAX_QUEUED_HTML, processQueue, readQueue, releaseQueue } from "./queue.ts";
import { saveWithFallback } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

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
      const b = JSON.parse((init as RequestInit).body as string);
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
    expect(JSON.parse((f.mock.calls[1]![1] as RequestInit).body as string).html).toBeUndefined();
  });
});
