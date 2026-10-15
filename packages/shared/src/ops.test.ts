import { describe, expect, it } from "vitest";
import { CreateItemRequest, ListItemsQuery, UpdateItemRequest, decodeListCursor, encodeListCursor } from "./api.ts";
import { uuidv7 } from "./ids.ts";
import { applyLww, clampAt, type ItemClock } from "./lww.ts";
import { OpClock } from "./hlc.ts";
import { Op, PullQuery, PushRequest } from "./ops.ts";

const itemId = uuidv7();
const at = 1760400723120;

describe("Op schema", () => {
  it("accepts every op type from design §8.2", () => {
    const ops = [
      { opId: "a1", type: "item.add", itemId, at, url: "https://example.com/post?utm_source=x", title: "Optional", tags: ["travel"], source: "share" },
      { opId: "a2", type: "item.setStatus", itemId, status: "archived", at },
      { opId: "a3", type: "item.setFavorite", itemId, value: true, at },
      { opId: "a4", type: "item.setProgress", itemId, progress: 0.42, anchor: 17, at },
      { opId: "a5", type: "item.tag", itemId, tag: "to-cook", present: true, at },
      { opId: "a6", type: "tag.rename", from: "ml", to: "machine-learning", at },
      { opId: "a7", type: "item.delete", itemId, at },
      { opId: "a8", type: "item.refresh", itemId, at },
      { opId: "a9", type: "item.setTitle", itemId, title: "New", at },
      { opId: "a10", type: "tag.delete", tag: "old", at },
    ];
    for (const o of ops) expect(Op.safeParse(o).success, o.type).toBe(true);
  });
  it("normalizes tag names", () => {
    const r = Op.parse({ opId: "x", type: "item.tag", itemId, tag: "  Machine   Learning ", present: true, at });
    expect(r.type === "item.tag" && r.tag).toBe("Machine Learning");
  });
  it("rejects bad ops", () => {
    expect(Op.safeParse({ opId: "x", type: "item.add", itemId, at, url: "javascript:alert(1)" }).success).toBe(false);
    expect(Op.safeParse({ opId: "x", type: "item.setProgress", itemId, at, progress: 1.5 }).success).toBe(false);
    expect(Op.safeParse({ opId: "x", type: "item.nope", itemId, at }).success).toBe(false);
    expect(Op.safeParse({ opId: "x", type: "item.tag", itemId, at, tag: "   ", present: true }).success).toBe(false);
    expect(Op.safeParse({ opId: "x", type: "item.setStatus", itemId: "nope", at, status: "unread" }).success).toBe(false);
  });
  it("limits push size", () => {
    const op = { opId: "x", type: "item.refresh", itemId, at };
    expect(PushRequest.safeParse({ deviceId: "dev_1", ops: Array(500).fill(op) }).success).toBe(true);
    expect(PushRequest.safeParse({ deviceId: "dev_1", ops: Array(501).fill(op) }).success).toBe(false);
    expect(PushRequest.safeParse({ deviceId: "bad id!", ops: [] }).success).toBe(false);
  });
  it("coerces pull query", () => {
    expect(PullQuery.parse({ cursor: "18000" })).toEqual({ cursor: 18000, limit: 500, full: false });
    expect(PullQuery.safeParse({ limit: "5000" }).success).toBe(false);
  });
});

describe("api schemas", () => {
  it("list query defaults", () => {
    expect(ListItemsQuery.parse({})).toEqual({ state: "unread", sort: "newest", limit: 30 });
  });
  it("patch requires a field", () => {
    expect(UpdateItemRequest.safeParse({}).success).toBe(false);
    expect(UpdateItemRequest.safeParse({ isFavorite: false }).success).toBe(true);
  });
  it("create item", () => {
    expect(CreateItemRequest.safeParse({ url: "https://a.b/c", html: "<html></html>", tags: ["x"] }).success).toBe(true);
    expect(CreateItemRequest.safeParse({ url: "file:///etc/passwd" }).success).toBe(false);
  });
  it("list cursor roundtrip", () => {
    const c = { k: 1760400723120, id: itemId };
    expect(decodeListCursor(encodeListCursor(c))).toEqual(c);
    expect(decodeListCursor("garbage!!")).toBeNull();
  });
});

describe("lww", () => {
  it("later at wins, ties by deviceId", () => {
    const clock: ItemClock = {};
    expect(applyLww(clock, "status", { at: 10, dev: "b" })).toBe(true);
    expect(applyLww(clock, "status", { at: 9, dev: "z" })).toBe(false);
    expect(applyLww(clock, "status", { at: 10, dev: "a" })).toBe(false);
    expect(applyLww(clock, "status", { at: 10, dev: "c" })).toBe(true);
    expect(applyLww(clock, "status", { at: 10, dev: "c" })).toBe(true); // same stamp: later-applied wins
    expect(clock.status).toEqual({ at: 10, dev: "c" });
  });
  it("clamps future", () => {
    expect(clampAt(10_000_000, 0)).toBe(300_000);
    expect(clampAt(5, 0)).toBe(5);
  });
  it("op clock is strictly increasing", () => {
    const c = new OpClock(() => 100);
    expect([c.next(), c.next(), c.next()]).toEqual([100, 101, 102]);
  });
});
