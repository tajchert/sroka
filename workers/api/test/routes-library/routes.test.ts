import { LIMITS, PARSER_VERSION, uuidv7, verifyContentPath } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { makeApp } from "./app.ts";

describe("POST /v1/items", () => {
  it("creates, enqueues a parse job, and re-adds duplicates", async () => {
    const { call, sent, user } = makeApp();
    const r = await call("POST", "/v1/items", { url: "https://ex.example/a?utm_source=x", tags: ["Birds"], source: "extension" });
    expect(r.status).toBe(202);
    expect(r.json.created).toBe(true);
    expect(r.json.item).toMatchObject({ canonicalUrl: "https://ex.example/a", tags: ["Birds"], parseStatus: "pending", source: "extension" });
    expect(sent).toEqual([{ userId: user, itemId: r.json.item.id, url: "https://ex.example/a?utm_source=x", parseGen: 1 }]);

    const again = await call("POST", "/v1/items", { url: "https://ex.example/a", tags: ["more"] });
    expect(again.status).toBe(202);
    expect(again.json.created).toBe(false);
    expect(again.json.item.id).toBe(r.json.item.id);
    expect(again.json.item.tags).toEqual(["Birds", "more"]);
    expect(sent).toHaveLength(1); // duplicate of a non-failed item → no new job
  });

  it("stores captured html gzipped in R2 and enqueues a forced private job", async () => {
    const { call, sent, user, env } = makeApp();
    const html = "<!doctype html><html><body><p>secret</p></body></html>";
    const r = await call("POST", "/v1/items", { url: "https://paywall.example/x", html });
    expect(r.status).toBe(202);
    const id = r.json.item.id;
    const rawKey = `raw/${user}/${id}.html.gz`;
    expect(sent).toEqual([{ userId: user, itemId: id, url: "https://paywall.example/x", rawKey, force: true, parseGen: 2 }]);
    const obj = await env.CONTENT.get(rawKey);
    const text = await new Response(obj!.body.pipeThrough(new DecompressionStream("gzip"))).text();
    expect(text).toBe(html);
  });

  it("validates", async () => {
    const { call } = makeApp();
    expect((await call("POST", "/v1/items", { url: "ftp://x" })).json).toEqual({ error: "invalid_url" });
    expect((await call("POST", "/v1/items", { url: 5 })).json.error).toBe("invalid_request");
    expect((await call("POST", "/v1/items", "{nope")).status).toBe(400);
    const big = "x".repeat(LIMITS.maxHtmlBytes + 1);
    expect((await call("POST", "/v1/items", { url: "https://a.example/", html: big })).status).toBe(413);
  });
});

describe("items CRUD", () => {
  it("get / patch / list / delete / refresh / content", async () => {
    const { call, sent, user, env } = makeApp();
    const created = (await call("POST", "/v1/items", { url: "https://c.example/1", tags: ["a", "b"] })).json.item;
    const id = created.id as string;
    expect((await call("GET", `/v1/items/${id}`)).json.item.id).toBe(id);
    expect((await call("GET", `/v1/items/${uuidv7()}`)).status).toBe(404);
    expect((await call("GET", `/v1/items/not-a-uuid`)).status).toBe(404);

    const p = await call("PATCH", `/v1/items/${id}`, { status: "archived", isFavorite: true, title: "T", progress: 0.3, progressAnchor: 4, tags: ["B", "c"] }, { "X-Sroka-Device": "web_1" });
    expect(p.status).toBe(200);
    expect(p.json.item).toMatchObject({ status: "archived", isFavorite: true, title: "T", progress: 0.3, progressAnchor: 4, tags: ["b", "c"] });
    const anchorOnly = await call("PATCH", `/v1/items/${id}`, { progressAnchor: 9 });
    expect(anchorOnly.json.item).toMatchObject({ progress: 0.3, progressAnchor: 9 });
    expect((await call("PATCH", `/v1/items/${id}`, {})).json).toMatchObject({ error: "invalid_request", message: "empty_patch" });
    const tooMany = await call("PATCH", `/v1/items/${id}`, { tags: Array.from({ length: 101 }, (_, i) => `t${i}`) });
    expect(tooMany.json).toEqual({ error: "invalid_request", message: "too_many_tags" });

    const list = await call("GET", "/v1/items?state=archived&limit=1");
    expect(list.json.items.map((i: { id: string }) => i.id)).toEqual([id]);
    expect((await call("GET", "/v1/items?url=https://c.example/1%23frag")).json.items).toHaveLength(1);
    expect((await call("GET", "/v1/items?url=notaurl")).json).toEqual({ error: "invalid_url" });
    expect((await call("GET", "/v1/items?cursor=zzz")).json).toMatchObject({ error: "invalid_request", message: "bad_cursor" });
    expect((await call("GET", "/v1/items?q=%22%28%29")).status).toBe(200);

    expect((await call("GET", `/v1/items/${id}/content`)).json).toEqual({ error: "not_parsed" });
    const lib = env.LIBRARY.getByName(user);
    const contentId = uuidv7();
    await lib.markParsed(id, {
      status: "ok", parseGen: 1, contentId, contentPrivate: false, title: "P", excerpt: null, siteName: null, author: null,
      lang: null, wordCount: 10, readingMinutes: 1, leadImageKey: "thumb.webp", parserVersion: PARSER_VERSION,
    });
    const content = await call("GET", `/v1/items/${id}/content`);
    expect(content.status).toBe(200);
    expect(content.json.articleUrl).toBe(content.json.baseUrl + "article.html");
    const v = await verifyContentPath(env.CONTENT_URL_SIGNING_KEY, new URL(content.json.articleUrl).pathname);
    expect(v).toMatchObject({ ok: true, r2Key: `content/${contentId}/article.html` });
    const item = (await call("GET", `/v1/items/${id}`)).json.item;
    expect(item.leadImageUrl).toBe(content.json.baseUrl + "thumb.webp");

    sent.length = 0;
    const refresh = await call("POST", `/v1/items/${id}/refresh`);
    expect(refresh.status).toBe(202);
    expect(refresh.json.item.parseStatus).toBe("pending");
    expect(sent).toEqual([{ userId: user, itemId: id, url: "https://c.example/1", force: true, parseGen: 2 }]);

    expect((await call("DELETE", `/v1/items/${id}`)).status).toBe(204);
    expect((await call("DELETE", `/v1/items/${id}`)).status).toBe(404);
    expect((await call("PATCH", `/v1/items/${id}`, { status: "unread" })).status).toBe(404);
    expect((await call("POST", `/v1/items/${id}/refresh`)).status).toBe(404);
    expect((await call("GET", `/v1/items/${id}`)).status).toBe(404);
  });
});

describe("tags routes", () => {
  it("list, suggestions, rename/merge, delete", async () => {
    const { call } = makeApp();
    await call("POST", "/v1/items", { url: "https://t.example/1", tags: ["ml", "x"] });
    await call("POST", "/v1/items", { url: "https://t.example/2", tags: ["Machine learning"] });
    const tags = (await call("GET", "/v1/tags")).json.tags as { id: string; name: string; count: number }[];
    expect(tags.map((t) => [t.name, t.count])).toEqual([["Machine learning", 1], ["ml", 1], ["x", 1]]);
    const ml = tags.find((t) => t.name === "ml")!;
    const target = tags.find((t) => t.name === "Machine learning")!;

    const sug = await call("GET", "/v1/tags/suggestions?url=https://t.example/1");
    expect(sug.json.current).toEqual(["ml", "x"]);
    expect((await call("GET", "/v1/tags/suggestions?url=bogus")).json.current).toEqual([]);

    const merged = await call("PATCH", `/v1/tags/${ml.id}`, { name: "machine LEARNING" });
    expect(merged.status).toBe(200);
    expect(merged.json.tag).toMatchObject({ id: target.id, name: "Machine learning", count: 2 });
    expect((await call("PATCH", `/v1/tags/${ml.id}`, { name: "zzz" })).status).toBe(404);
    const renamed = await call("PATCH", `/v1/tags/${target.id}`, { name: "ML" });
    expect(renamed.json.tag).toMatchObject({ id: target.id, name: "ML", count: 2 });

    expect((await call("DELETE", `/v1/tags/${target.id}`)).status).toBe(204);
    expect((await call("DELETE", `/v1/tags/${target.id}`)).status).toBe(404);
    expect((await call("GET", "/v1/tags")).json.tags.map((t: { name: string }) => t.name)).toEqual(["x"]);
  });
});

describe("sync routes", () => {
  it("push validates ops individually, enqueues jobs; pull pages", async () => {
    const { call, sent } = makeApp();
    const a = uuidv7();
    const push = await call("POST", "/v1/sync/push", {
      deviceId: "dev_1",
      ops: [
        { opId: "o1", type: "item.add", itemId: a, url: "https://s.example/", at: 1_760_000_000_000 },
        { opId: "o2", type: "item.bogus" },
        { type: "item.add" },
      ],
    });
    expect(push.status).toBe(200);
    expect(push.json).toEqual({
      applied: ["o1"],
      rejected: [{ opId: "o2", reason: "invalid_op" }, { opId: "", reason: "invalid_op" }],
      aliases: {},
      cursor: 1,
    });
    expect(sent).toHaveLength(1);
    expect((await call("POST", "/v1/sync/push", { deviceId: "bad id!", ops: [] })).status).toBe(400);
    expect((await call("POST", "/v1/sync/push", { deviceId: "d", ops: new Array(501).fill({}) })).status).toBe(400);

    const pull = await call("GET", "/v1/sync/pull?cursor=0&limit=10");
    expect(pull.json).toMatchObject({ cursor: 1, hasMore: false, deleted: { items: [], tags: [] } });
    expect(pull.json.items[0].id).toBe(a);
    expect((await call("GET", "/v1/sync/pull?limit=0")).status).toBe(400);
  });
});
