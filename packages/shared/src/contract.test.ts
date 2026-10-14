import { describe, expect, it } from "vitest";
import { CreateItemRequest, toApiError } from "./api.ts";
import { pairWins } from "./lww.ts";
import { tagKey } from "./model.ts";
import { ParseJobSchema, ParseResultSchema } from "./parse.ts";

const CID = "0192f3c4-1111-7222-8333-444455556666";
const meta = { title: null, excerpt: null, siteName: null, author: null, lang: null, wordCount: null, readingMinutes: null, parserVersion: 1 };

describe("toApiError", () => {
  it("maps a lone invalid_url issue to {error:'invalid_url'}", () => {
    const r = CreateItemRequest.safeParse({ url: "javascript:alert(1)" });
    expect(r.success).toBe(false);
    if (!r.success) expect(toApiError(r.error)).toEqual({ error: "invalid_url" });
  });
  it("other failures → invalid_request with issues", () => {
    const r = CreateItemRequest.safeParse({ url: "javascript:alert(1)", tags: "nope" });
    expect(r.success).toBe(false);
    if (!r.success) {
      const e = toApiError(r.error);
      expect(e.error).toBe("invalid_request");
      expect(e.issues?.length).toBe(2);
    }
  });
});

describe("ParseResult invariants", () => {
  it("contentId required for ok/partial, absent for failed", () => {
    expect(ParseResultSchema.safeParse({ ...meta, status: "ok", parseGen: 1, contentId: CID, contentPrivate: false }).success).toBe(true);
    expect(ParseResultSchema.safeParse({ ...meta, status: "partial", parseGen: 1, contentPrivate: false }).success).toBe(false);
    expect(ParseResultSchema.safeParse({ ...meta, status: "failed", parseGen: 1, contentId: CID, contentPrivate: false }).success).toBe(false);
    expect(ParseResultSchema.safeParse({ ...meta, status: "failed", parseGen: 1, contentPrivate: false, error: "http_404" }).success).toBe(true);
  });
  it("job carries parseGen", () => {
    const job = { userId: "u1", itemId: CID, url: "https://a.b/" };
    expect(ParseJobSchema.safeParse(job).success).toBe(false);
    expect(ParseJobSchema.safeParse({ ...job, parseGen: 3 }).success).toBe(true);
  });
});

describe("tags", () => {
  it("tagKey folds non-ASCII case", () => {
    expect(tagKey("  Żółw ")).toBe(tagKey("żółw"));
    expect(tagKey("Éte")).toBe("éte");
    expect(tagKey("Machine   Learning")).toBe("machine learning");
  });
  it("pairWins uses (at, dev) like item fields", () => {
    expect(pairWins({ at: 10, dev: "a" }, undefined)).toBe(true);
    expect(pairWins({ at: 10, dev: "a" }, { at: 10, dev: "b" })).toBe(false);
    expect(pairWins({ at: 10, dev: "c" }, { at: 10, dev: "b" })).toBe(true);
    expect(pairWins({ at: 9, dev: "z" }, { at: 10, dev: "a" })).toBe(false);
  });
});
