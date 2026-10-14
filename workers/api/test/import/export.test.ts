import { describe, expect, it } from "vitest";
import { parseImport } from "../../src/import/parsers.ts";
import { makeApp } from "./helpers.ts";

async function seed(t: ReturnType<typeof makeApp>) {
  const stub = t.env.LIBRARY.getByName(t.user);
  const at = Date.now();
  const add = (n: number, extra: object) => ({ type: "item.add", opId: `o${n}`, at, itemId: crypto.randomUUID(), source: "web", ...extra });
  await stub.applyOps("dev1", [
    add(1, { url: "https://example.com/old", title: 'Old, "quoted"', savedAt: 1600000000_000, tags: ["a", "b c"], status: "archived", isFavorite: true }),
    add(2, { url: "https://example.com/new", title: "New\nline", savedAt: 1700000000_000, tags: [] }),
  ]);
}

describe("GET /v1/exports", () => {
  it("csv: Pocket-compatible header, newest first, RFC 4180 quoting, attachment headers", async () => {
    const t = makeApp();
    await seed(t);
    const res = await t.raw("/v1/exports?format=csv");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/csv; charset=utf-8");
    expect(res.headers.get("content-disposition")).toMatch(/^attachment; filename="sroka-export-\d{4}-\d{2}-\d{2}\.csv"$/);
    const text = await res.text();
    expect(text.startsWith("title,url,time_added,tags,status,favorite\r\n")).toBe(true);
    expect(text).toContain('"New\nline",https://example.com/new,1700000000,,unread,0\r\n');
    expect(text).toContain('"Old, ""quoted""",https://example.com/old,1600000000,a|b c,archive,1\r\n');
    expect(text.indexOf("/new")).toBeLessThan(text.indexOf("/old"));
  });

  it("csv round-trips through the pocket_csv importer", async () => {
    const t = makeApp();
    await seed(t);
    const text = await (await t.raw("/v1/exports?format=csv")).text();
    const p = parseImport("pocket_csv", new TextEncoder().encode(text));
    expect(p.invalid).toBe(0);
    expect(p.rows.map((r) => r.url)).toEqual(["https://example.com/new", "https://example.com/old"]);
    expect(p.rows[1]).toMatchObject({ title: 'Old, "quoted"', tags: ["a", "b c"], status: "archived", isFavorite: true, savedAt: 1600000000_000 });
  });

  it("json: ExportJson with items and tags", async () => {
    const t = makeApp();
    await seed(t);
    const res = await t.raw("/v1/exports?format=json");
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(res.headers.get("content-disposition")).toMatch(/\.json"$/);
    const j = (await res.json()) as any;
    expect(j).toMatchObject({ format: "sroka-export", version: 1 });
    expect(j.items.map((i: any) => i.url)).toEqual(["https://example.com/new", "https://example.com/old"]);
    expect(j.items[1]).toMatchObject({ title: 'Old, "quoted"', status: "archived", isFavorite: true, tags: ["a", "b c"], savedAt: 1600000000_000 });
  });

  it("defaults to json, 400 on a bad format, valid output for an empty library", async () => {
    const t = makeApp();
    expect((await t.raw("/v1/exports?format=xml")).status).toBe(400);
    const j = (await (await t.raw("/v1/exports")).json()) as any;
    expect(j.items).toEqual([]);
    expect(await (await t.raw("/v1/exports?format=csv")).text()).toBe("title,url,time_added,tags,status,favorite\r\n");
  });
});
