import { describe, expect, it } from "vitest";
import { buildContentUrls, defaultExp, signContentPath, verifyContentPath } from "./content-sign.ts";

const KEY = "test-secret-0123456789-abcdefghijklmnop";
const CID = "0192f3c4-1111-7222-8333-444455556666";
const NOW = 1_800_000_000_000;

describe("content signing", () => {
  it("roundtrips public scope", async () => {
    const u = await buildContentUrls({ origin: "https://c.sroka.app/", secret: KEY, scope: "p", contentId: CID, now: NOW });
    expect(u.baseUrl).toMatch(/^https:\/\/c\.sroka\.app\/s\/\d+\/[A-Za-z0-9_-]{43}\/p\/0192f3c4-1111-7222-8333-444455556666\/$/);
    expect(u.articleUrl).toBe(u.baseUrl + "article.html");
    expect(u.packageUrl).toBe(u.baseUrl + "package.zip");
    const path = new URL(u.baseUrl + "img/abc.webp").pathname;
    const r = await verifyContentPath(KEY, path, NOW / 1000);
    expect(r).toMatchObject({ ok: true, scope: "p", contentId: CID, file: "img/abc.webp", r2Key: `content/${CID}/img/abc.webp`, isPrivate: false });
    expect(u.expiresAt).toBe(defaultExp(NOW) * 1000);
  });
  it("roundtrips private scope", async () => {
    const u = await buildContentUrls({ origin: "http://127.0.0.1:8787", secret: KEY, scope: "u.AbC123_x", contentId: CID, now: NOW });
    const r = await verifyContentPath(KEY, new URL(u.articleUrl).pathname, NOW / 1000);
    expect(r).toMatchObject({ ok: true, r2Key: `private/AbC123_x/${CID}/article.html`, isPrivate: true });
  });
  it("rejects tampering", async () => {
    const exp = 1_800_100_000;
    const sig = await signContentPath(KEY, exp, "u.alice", CID);
    const now = 1_800_000_000;
    expect((await verifyContentPath(KEY, `/s/${exp}/${sig}/u.alice/${CID}/article.html`, now)).ok).toBe(true);
    expect(await verifyContentPath(KEY, `/s/${exp}/${sig}/u.bob/${CID}/article.html`, now)).toEqual({ ok: false, reason: "bad_signature" });
    expect(await verifyContentPath(KEY, `/s/${exp + 1}/${sig}/u.alice/${CID}/article.html`, now)).toEqual({ ok: false, reason: "bad_signature" });
    expect(await verifyContentPath(KEY, `/s/${exp}/${sig}/p/${CID}/article.html`, now)).toEqual({ ok: false, reason: "bad_signature" });
    expect(await verifyContentPath("other-key", `/s/${exp}/${sig}/u.alice/${CID}/article.html`, now)).toEqual({ ok: false, reason: "bad_signature" });
  });
  it("rejects expired", async () => {
    const exp = 1_800_000_000;
    const sig = await signContentPath(KEY, exp, "p", CID);
    expect(await verifyContentPath(KEY, `/s/${exp}/${sig}/p/${CID}/a.html`, exp + 1)).toEqual({ ok: false, reason: "expired" });
  });
  it("rejects malformed paths and traversal", async () => {
    const exp = 1_900_000_000;
    const sig = await signContentPath(KEY, exp, "p", CID);
    for (const p of [
      `/s/${exp}/${sig}/p/${CID}/`,
      `/s/${exp}/${sig}/p/${CID}/../x`,
      `/s/${exp}/${sig}/p/${CID}/img/..%2fx`,
      `/s/${exp}/${sig}/p/not-a-uuid/a.html`,
      `/s/abc/${sig}/p/${CID}/a.html`,
      `/s/${exp}/${sig}/x.y/${CID}/a.html`,
      `/t/${exp}/${sig}/p/${CID}/a.html`,
    ]) {
      expect((await verifyContentPath(KEY, p, 1_800_000_000)).ok, p).toBe(false);
    }
  });
  it("signature is bound to the contentId", async () => {
    const exp = 1_800_100_000;
    const CID2 = "0192f3c4-1111-7222-8333-444455556667";
    const sig = await signContentPath(KEY, exp, "u.alice", CID);
    expect(await verifyContentPath(KEY, `/s/${exp}/${sig}/u.alice/${CID2}/article.html`, 1_800_000_000)).toEqual({ ok: false, reason: "bad_signature" });
  });
  it("rejects non-canonical exp and sig encodings", async () => {
    const exp = 1_800_100_000;
    const now = 1_800_000_000;
    const sig = await signContentPath(KEY, exp, "p", CID);
    expect((await verifyContentPath(KEY, `/s/${exp}/${sig}/p/${CID}/a.html`, now)).ok).toBe(true);
    // leading zero on exp
    expect(await verifyContentPath(KEY, `/s/0${exp}/${sig}/p/${CID}/a.html`, now)).toEqual({ ok: false, reason: "malformed" });
    // same bytes, different spare bits in the last char
    const ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const last = ALPHA.indexOf(sig[42]!);
    const alt = sig.slice(0, 42) + ALPHA[last ^ 1];
    expect(await verifyContentPath(KEY, `/s/${exp}/${alt}/p/${CID}/a.html`, now)).toEqual({ ok: false, reason: "bad_signature" });
    // padded / wrong length
    expect((await verifyContentPath(KEY, `/s/${exp}/${sig}=/p/${CID}/a.html`, now)).ok).toBe(false);
    expect((await verifyContentPath(KEY, `/s/${exp}/${sig.slice(0, 42)}/p/${CID}/a.html`, now)).ok).toBe(false);
  });
  it("file segment count and empty segments", async () => {
    const exp = 1_900_000_000;
    const now = 1_800_000_000;
    const sig = await signContentPath(KEY, exp, "p", CID);
    const base = `/s/${exp}/${sig}/p/${CID}/`;
    expect((await verifyContentPath(KEY, base + "a/b/c/d.webp", now)).ok).toBe(true);
    expect(await verifyContentPath(KEY, base + "a/b/c/d/e.webp", now)).toEqual({ ok: false, reason: "malformed" });
    expect(await verifyContentPath(KEY, base + "img//a.webp", now)).toEqual({ ok: false, reason: "malformed" });
    expect(await verifyContentPath(KEY, `/s/${exp}/${sig}//p/${CID}/a.html`, now)).toEqual({ ok: false, reason: "malformed" });
  });
  it("rejects percent-encoded traversal (pathname must not be decoded)", async () => {
    const exp = 1_900_000_000;
    const sig = await signContentPath(KEY, exp, "p", CID);
    const base = `/s/${exp}/${sig}/p/${CID}/`;
    for (const f of ["%2e%2e/x", "%2E%2E/x", "img/%2e%2e%2fx", "img%2Fa.webp", "img%2fa.webp", "%2e%2E%2F%2e%2e%2Fprivate"]) {
      expect((await verifyContentPath(KEY, base + f, 1_800_000_000)).ok, f).toBe(false);
    }
    // what a Worker actually sees: new URL(...).pathname keeps %2F / %2e encoded
    const p = new URL(`https://c.sroka.app${base}img%2F..%2Fx`).pathname;
    expect((await verifyContentPath(KEY, p, 1_800_000_000)).ok).toBe(false);
  });
});
