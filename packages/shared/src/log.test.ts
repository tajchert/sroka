import { afterEach, describe, expect, it, vi } from "vitest";
import { buildRecord, hashId, log, maskEmail } from "./log.ts";
import { writeMetric } from "./metrics.ts";

afterEach(() => vi.restoreAllMocks());

describe("logger redaction", () => {
  it("masks emails", () => {
    expect(maskEmail("jane.doe@example.com")).toBe("j***@example.com");
  });
  it("redacts sensitive keys and masks emails in values", () => {
    const r = buildRecord("info", "hello jane@example.com", {
      event: "x",
      otp: "123456",
      cookie: "a=b",
      authorization: "Bearer abc.def",
      sessionToken: "t",
      html: "<p>secret article</p>",
      email: "bob@example.org",
      nested: { password: "p", note: "mail me at z@y.io", ok: 1 },
      errMessage: "Bearer abc123 failed",
    });
    const s = JSON.stringify(r);
    for (const bad of ["123456", "a=b", "abc.def", "secret article", "bob@", "z@y", "abc123", "jane@"]) {
      expect(s).not.toContain(bad);
    }
    expect(r.email).toBe("b***@example.org");
    expect((r.nested as Record<string, unknown>).ok).toBe(1);
    expect(r.event).toBe("x");
  });
  it("emits one JSON line per call on the right console method", () => {
    const e = vi.spyOn(console, "error").mockImplementation(() => {});
    const l = vi.spyOn(console, "log").mockImplementation(() => {});
    log.exception("boom", new Error("bad"), { event: "t" });
    log.info("fine", { event: "t2" });
    const rec = JSON.parse(e.mock.calls[0]![0] as string);
    expect(rec).toMatchObject({ level: "error", msg: "boom", event: "t", errName: "Error", errMessage: "bad" });
    expect(rec.stack).toBeTypeOf("string");
    expect(JSON.parse(l.mock.calls[0]![0] as string)).toMatchObject({ level: "info", event: "t2" });
  });
  it("hashId is stable and short", async () => {
    const a = await hashId("user-1");
    expect(a).toHaveLength(12);
    expect(a).toBe(await hashId("user-1"));
    expect(a).not.toBe(await hashId("user-2"));
  });
});

describe("writeMetric", () => {
  it("is a no-op without a binding and never throws", () => {
    expect(() => writeMetric(undefined, { event: "x" })).not.toThrow();
    expect(() =>
      writeMetric({ writeDataPoint: () => { throw new Error("x"); } }, { event: "x" }),
    ).not.toThrow();
  });
  it("lays out blobs/doubles/index", () => {
    const w = vi.fn();
    writeMetric({ writeDataPoint: w }, { event: "parse", blobs: ["a.com", null], doubles: [5], index: "a.com" });
    expect(w).toHaveBeenCalledWith({ blobs: ["parse", "a.com", ""], doubles: [5], indexes: ["a.com"] });
  });
});
