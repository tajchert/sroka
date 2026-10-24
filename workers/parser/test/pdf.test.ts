import { env as rawEnv } from "cloudflare:workers";
import { ParseResultSchema, PDF_FILE, r2Keys, type ParseJob, type ParseResult } from "@sroka/shared";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.ts";
import type { ParserEnv } from "../src/env.ts";
import { migrateD1 } from "./d1.ts";
import { buildPdf } from "./pdf-fixture.ts";

const base = rawEnv as unknown as ParserEnv;
const ITEM = "0192f3c4-1111-7000-8000-0000000000cc";
const CID = "0192f3c4-2222-7000-8000-0000000000dd";
const dir = r2Keys.contentDir(CID, "u1");
const job = (over: Partial<ParseJob> = {}): ParseJob => ({ userId: "u1", itemId: ITEM, url: "http://localhost:8787/pdf/abc", parseGen: 2, pdf: { contentId: CID }, ...over });

let marked: ParseResult[];
let wanted: boolean[];
let markOk: boolean;
let getFails = false;
const env = (): ParserEnv => ({
  ...base,
  LIBRARY: {
    getByName: () => ({
      markParsed: async (_id: string, r: ParseResult) => (marked.push(r), { ok: markOk }),
      parseWanted: async () => wanted.shift() ?? true,
      reemitContentRefs: async () => ({ refs: 0, pending: 0 }),
    }),
  },
  CONTENT: getFails ? ({ ...base.CONTENT, get: async () => { throw new Error("r2 down"); }, put: base.CONTENT.put.bind(base.CONTENT), delete: base.CONTENT.delete.bind(base.CONTENT) } as unknown as R2Bucket) : base.CONTENT,
});
const msg = (body: unknown, attempts = 1) => ({ body, attempts, ack: vi.fn(), retry: vi.fn() });
const run = (m: ReturnType<typeof msg>, queue = "sroka-parse") => worker.queue({ queue, messages: [m] } as never, env());
const put = (bytes: Uint8Array) => base.CONTENT.put(dir + PDF_FILE, bytes);
const attempts = () => base.DB.prepare("SELECT * FROM parse_attempts ORDER BY created_at DESC").all<Record<string, unknown>>().then((r) => r.results);

beforeAll(async () => {
  await migrateD1(base.DB);
});
beforeEach(async () => {
  marked = [];
  wanted = [];
  markOk = true;
  getFails = false;
  await base.DB.exec("DELETE FROM content");
  await base.DB.exec("DELETE FROM parse_attempts");
  const l = await base.CONTENT.list({ prefix: "private/" });
  await Promise.all(l.objects.map((o) => base.CONTENT.delete(o.key)));
});
afterEach(() => vi.restoreAllMocks());

describe("pdf jobs", () => {
  it("extracts text + metadata, writes text.txt, never fetches or touches the cache", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const body = "The quick brown fox jumps over the lazy dog. ";
    const pdf = buildPdf({ pages: [body.repeat(2), "Second page text"], title: "Microsoft Word - Fox Report.docx", author: "Jane Doe", lang: "en-US" });
    await put(pdf);
    const m = msg(job());
    await run(m);
    expect(m.ack).toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
    const r = marked[0]!;
    expect(ParseResultSchema.parse(r)).toBeTruthy();
    expect(r).toMatchObject({ status: "ok", parseGen: 2, contentId: CID, contentPrivate: true, title: "Fox Report", author: "Jane Doe", lang: "en-US", siteName: "PDF" });
    expect(r.error).toBeUndefined();
    expect(r.wordCount).toBe(2 * 9 + 3);
    expect(r.readingMinutes).toBe(1);
    expect(r.excerpt).toMatch(/^The quick brown fox/);
    const text = await (await base.CONTENT.get(dir + "text.txt"))!.text();
    expect(text).toContain("Second page text");
    expect((await base.CONTENT.get(dir + PDF_FILE))!.size).toBe(pdf.byteLength);
    expect(await base.DB.prepare("SELECT COUNT(*) AS n FROM content").first<{ n: number }>()).toEqual({ n: 0 });
    const a = (await attempts())[0]!;
    expect(a).toMatchObject({ method: "pdf", url: null, status: "ok", item_id: ITEM, domain: "pdf" });
  });

  it("generic metadata title -> null (keeps provisional title)", async () => {
    await put(buildPdf({ pages: ["some words here"], title: "Untitled" }));
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "ok", title: null, wordCount: 3 });
  });

  it("scan without text -> ok + pdf_no_text, no text.txt", async () => {
    await put(buildPdf({ pages: [""], title: "Scan" }));
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "ok", contentId: CID, error: "pdf_no_text", title: null, wordCount: null, excerpt: null });
    expect(await base.CONTENT.head(dir + "text.txt")).toBeNull();
    expect((await attempts())[0]).toMatchObject({ status: "ok", error_code: "pdf_no_text" });
  });

  it("encrypted PDF -> ok + pdf_encrypted", async () => {
    await put(buildPdf({ pages: ["secret"], encrypt: true }));
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "ok", error: "pdf_encrypted", title: null });
  });

  it("garbage bytes -> ok + pdf_extract_failed", async () => {
    await put(new TextEncoder().encode("%PDF-1.4 this is not really a pdf"));
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "ok", error: "pdf_extract_failed", contentId: CID });
  });

  it("caps text at 300 pages", async () => {
    const pages = Array.from({ length: 305 }, (_, i) => `page${i + 1}`);
    await put(buildPdf({ pages }));
    await run(msg(job()));
    const text = await (await base.CONTENT.get(dir + "text.txt"))!.text();
    expect(text).toContain("page300");
    expect(text).not.toContain("page301");
  });

  it("skips superseded jobs and never writes text.txt", async () => {
    await put(buildPdf({ pages: ["hello world"] }));
    wanted = [true, false];
    const m = msg(job());
    await run(m);
    expect(m.ack).toHaveBeenCalled();
    expect(marked).toHaveLength(0);
    expect(await base.CONTENT.head(dir + "text.txt")).toBeNull();
  });

  it("R2 read failure is transient (retry); missing object -> failed", async () => {
    await put(buildPdf({ pages: ["hello world"] }));
    getFails = true;
    const m = msg(job());
    await run(m);
    expect(m.retry).toHaveBeenCalled();
    expect(marked).toHaveLength(0);
    getFails = false;
    await base.CONTENT.delete(dir + PDF_FILE);
    await run(msg(job()));
    expect(marked[0]).toMatchObject({ status: "failed", error: "pdf_missing" });
    expect(marked[0]!.contentId).toBeUndefined();
  });

  it("markParsed ok:false removes only text.txt, never document.pdf", async () => {
    await put(buildPdf({ pages: ["hello world"] }));
    markOk = false;
    await run(msg(job()));
    expect(await base.CONTENT.head(dir + "text.txt")).toBeNull();
    expect(await base.CONTENT.head(dir + PDF_FILE)).not.toBeNull();
  });

  it("DLQ marks failed without touching R2", async () => {
    await put(buildPdf({ pages: ["hello world"] }));
    const m = msg(job(), 4);
    await run(m, "sroka-parse-dlq");
    expect(m.ack).toHaveBeenCalled();
    expect(marked[0]).toMatchObject({ status: "failed", parseGen: 2 });
    expect(await base.CONTENT.head(dir + PDF_FILE)).not.toBeNull();
    expect((await attempts())[0]).toMatchObject({ method: "pdf", url: null, status: "failed" });
  });
});
