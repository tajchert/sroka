import { strToU8, zipSync } from "fflate";
import { describe, expect, it } from "vitest";
import { parseCsv } from "../../src/import/csv.ts";
import { ImportParseError, parseImport } from "../../src/import/parsers.ts";
import { INSTAPAPER_CSV, INSTAPAPER_CSV_OLD, NETSCAPE_HTML, POCKET_CSV, POCKET_HTML } from "./fixtures.ts";

const b = (s: string) => new TextEncoder().encode(s);

describe("parseCsv", () => {
  it("handles quotes, embedded newlines, CRLF and BOM", () => {
    expect(parseCsv('﻿a,b\r\n"x,1","y ""q"""\r\n\r\nlast,')).toEqual([
      ["a", "b"],
      ["x,1", 'y "q"'],
      ["last", ""],
    ]);
  });
});

describe("pocket_csv", () => {
  const p = parseImport("pocket_csv", b(POCKET_CSV));
  it("counts invalid URLs and parses rows newest first", () => {
    expect(p.invalid).toBe(2);
    expect(p.rows.map((r) => r.url)).toEqual([
      "https://example.com/a?utm_source=x",
      "https://example.com/c",
      "https://example.com/b",
      "https://example.com/ü",
    ]);
  });
  it("maps time, tags, status, title", () => {
    expect(p.rows[0]).toMatchObject({ title: "Hello, World", savedAt: 1700000000_000, tags: ["tech", "rust"], status: "unread", isFavorite: false });
    expect(p.rows[2]!.title).toBe('Multi\nline "quoted" title');
    expect(p.rows[2]!.tags).toEqual(["one", "two"]); // comma-separated fallback
    expect(p.rows[2]!.status).toBe("archived");
  });
  it("dedupes tags case-insensitively and drops zero timestamps", () => {
    expect(p.rows[3]!.tags).toEqual(["Żółw"]);
    expect(p.rows[3]!.savedAt).toBeUndefined();
  });
  it("accepts the optional favorite column (own export round-trip)", () => {
    const r = parseImport("pocket_csv", b("title,url,time_added,tags,status,favorite\nT,https://e.com/x,5,a|b,archive,1\n"));
    expect(r.rows[0]).toMatchObject({ isFavorite: true, status: "archived", tags: ["a", "b"], savedAt: 5000 });
  });
  it("reads CSVs from a zip (2025 export)", () => {
    const zip = zipSync({
      "part_000000.csv": strToU8("title,url,time_added,tags,status\nA,https://e.com/1,100,,unread\n"),
      "part_000001.csv": strToU8("title,url,time_added,tags,status\nB,https://e.com/2,200,,archive\n"),
      "__MACOSX/._part.csv": strToU8("junk"),
    });
    const r = parseImport("pocket_csv", zip);
    expect(r.rows.map((x) => x.url)).toEqual(["https://e.com/2", "https://e.com/1"]);
  });
  it("rejects a CSV without a url column and an empty zip", () => {
    expect(() => parseImport("pocket_csv", b("a,b\n1,2\n"))).toThrow(ImportParseError);
    expect(() => parseImport("pocket_csv", zipSync({ "x.txt": strToU8("hi") }))).toThrow(/no CSV/);
  });
});

describe("pocket_html", () => {
  const p = parseImport("pocket_html", b(POCKET_HTML));
  it("splits Unread / Read Archive sections", () => {
    expect(p.invalid).toBe(1);
    expect(p.rows.map((r) => [r.url, r.status])).toEqual([
      ["https://example.com/u2", "unread"],
      ["https://example.com/u1", "unread"],
      ["https://example.com/r1", "archived"],
    ]);
  });
  it("decodes entities, tags and time_added", () => {
    const u1 = p.rows.find((r) => r.url.endsWith("u1"))!;
    expect(u1).toMatchObject({ title: "First & best", tags: ["news", "tech"], savedAt: 1700000100_000 });
  });
});

describe("instapaper_csv", () => {
  const p = parseImport("instapaper_csv", b(INSTAPAPER_CSV));
  const by = (n: string) => p.rows.find((r) => r.url.endsWith(n))!;
  it("maps folders", () => {
    expect(by("i1")).toMatchObject({ status: "unread", isFavorite: false, tags: ["a", "b"], savedAt: 1700000000_000 });
    expect(by("i2")).toMatchObject({ status: "archived", tags: [] });
    expect(by("i3")).toMatchObject({ status: "unread", isFavorite: true });
    expect(by("i4")).toMatchObject({ status: "unread", tags: ["Recipes"] });
    expect(by("i5").savedAt).toBeUndefined();
  });
  it("works without the Tags column", () => {
    const r = parseImport("instapaper_csv", b(INSTAPAPER_CSV_OLD));
    expect(r.rows).toHaveLength(1);
    expect(r.rows[0]!.tags).toEqual([]);
  });
});

describe("netscape_html", () => {
  const p = parseImport("netscape_html", b(NETSCAPE_HTML));
  it("parses ADD_DATE/TAGS, ignores folders and place: links", () => {
    expect(p.invalid).toBe(1);
    expect(p.rows.map((r) => r.url)).toEqual([
      "https://example.com/n3?a=1&b=2",
      "https://example.com/n2",
      "https://example.com/n1",
    ]);
    expect(p.rows[2]).toMatchObject({ title: "Netscape one", tags: ["x", "y z"], status: "unread", savedAt: 1700000500_000 });
  });
});

describe("hardening", () => {
  it("scans pathological unclosed anchors in linear time", () => {
    const html = "<a href=x>".repeat(20000);
    const t0 = Date.now();
    parseImport("netscape_html", new TextEncoder().encode(html));
    expect(Date.now() - t0).toBeLessThan(2000);
  });
  it("rejects zip bombs", async () => {
    const { zipSync } = await import("fflate");
    const big = new Uint8Array(45 * 1024 * 1024);
    const z = zipSync({ "a.csv": big });
    expect(() => parseImport("pocket_csv", z)).toThrow(/too large/);
  });
});
