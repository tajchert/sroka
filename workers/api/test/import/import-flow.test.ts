import { IMPORT_DEVICE_ID } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { getJob } from "../../src/import/jobs.ts";
import { type ImportParams, runImport } from "../../src/import/workflow.ts";
import { NETSCAPE_HTML, POCKET_CSV } from "./fixtures.ts";
import { makeApp } from "./helpers.ts";

function fakeStep() {
  const names: string[] = [];
  return {
    names,
    async do(name: string, a: any, b?: any) {
      names.push(name);
      return (b ?? a)();
    },
    async sleep(name: string) {
      names.push(name);
    },
  } as any;
}

function form(format: string, content: string | Uint8Array, filename = "f.csv") {
  const fd = new FormData();
  fd.set("format", format);
  fd.set("file", new File([content as any], filename));
  return fd;
}

describe("POST /v1/imports", () => {
  it("415 for non-multipart, 400 for bad format / missing file", async () => {
    const t = makeApp();
    expect((await t.raw("/v1/imports", { method: "POST", body: "{}", headers: { "content-type": "application/json" } })).status).toBe(415);
    expect((await t.raw("/v1/imports", { method: "POST", body: form("nope", "x") })).status).toBe(400);
    const fd = new FormData();
    fd.set("format", "pocket_csv");
    expect((await t.raw("/v1/imports", { method: "POST", body: fd })).status).toBe(400);
  });

  it("413 for oversized uploads", async () => {
    const t = makeApp();
    const big = new Uint8Array(20 * 1024 * 1024 + 1);
    expect((await t.raw("/v1/imports", { method: "POST", body: form("pocket_csv", big) })).status).toBe(413);
  });

  it("stores the upload, creates the job + workflow instance; GET returns the job only to the owner", async () => {
    const t = makeApp();
    const res = await t.raw("/v1/imports", { method: "POST", body: form("pocket_csv", POCKET_CSV) });
    expect(res.status).toBe(202);
    const { job } = (await res.json()) as any;
    expect(job).toMatchObject({ kind: "import", status: "queued", format: "pocket_csv", total: null, done: 0, skipped: 0, error: null });
    expect(t.created).toHaveLength(1);
    expect(t.created[0]!.id).toBe(job.id);
    const params = t.created[0]!.params as ImportParams;
    expect(params.uploadKey).toBe(`uploads/${t.user}/${job.id}.csv`);
    expect(await t.env.CONTENT.head(params.uploadKey)).not.toBeNull();

    const got = await t.raw(`/v1/imports/${job.id}`);
    expect(got.status).toBe(200);
    expect(((await got.json()) as any).job.id).toBe(job.id);
    expect((await t.raw(`/v1/imports/${job.id}`, {}, "someone_else")).status).toBe(404);
    expect((await t.raw(`/v1/imports/00000000-0000-0000-0000-000000000000`)).status).toBe(404);
  });

  it("the daily limit holds under concurrent requests (atomic reservation)", async () => {
    const t = makeApp();
    const res = await Promise.all(Array.from({ length: 15 }, () => t.raw("/v1/imports", { method: "POST", body: form("pocket_csv", POCKET_CSV) })));
    const codes = res.map((r) => r.status);
    expect(codes.filter((c) => c === 202)).toHaveLength(10);
    expect(codes.filter((c) => c === 429)).toHaveLength(5);
    expect(t.created).toHaveLength(10);
  });

  it("503s and fails the job when the workflow cannot start", async () => {
    const t = makeApp({ workflowFails: true });
    expect((await t.raw("/v1/imports", { method: "POST", body: form("pocket_csv", POCKET_CSV) })).status).toBe(503);
  });
});

describe("runImport (workflow body)", () => {
  async function start(t: ReturnType<typeof makeApp>, format: string, content: string, filename: string) {
    const res = await t.raw("/v1/imports", { method: "POST", body: form(format, content, filename) });
    const { job } = (await res.json()) as any;
    return { id: job.id as string, params: t.created.at(-1)!.params as ImportParams };
  }

  it("imports a Pocket CSV: items, tags, status, savedAt, parse jobs newest first, progress, cleanup", async () => {
    const t = makeApp();
    const { id, params } = await start(t, "pocket_csv", POCKET_CSV, "a.csv");
    const out = await runImport(t.env, params, fakeStep(), { throttle: false });
    expect(out.status).toBe("done");

    expect(await getJob(t.env.DB, t.user, id)).toMatchObject({ status: "done", total: 6, done: 6, skipped: 2, error: null });

    const items = await t.env.LIBRARY.getByName(t.user).exportItems();
    expect(items).toHaveLength(4);
    const a = items.find((i) => i.url.includes("/a"))!;
    expect(a).toMatchObject({ status: "unread", savedAt: 1700000000_000, source: "import", title: "Hello, World" });
    expect([...a.tags].sort()).toEqual(["rust", "tech"]);
    expect(items.find((i) => i.url.endsWith("/b"))).toMatchObject({ status: "archived" });

    expect(t.sent.map((j) => j.url)).toEqual([
      "https://example.com/a?utm_source=x",
      "https://example.com/c",
      "https://example.com/b",
      "https://example.com/ü",
    ]);
    expect(await t.env.CONTENT.head(params.uploadKey)).toBeNull();
    expect((await t.env.CONTENT.list({ prefix: `uploads/${t.user}/` })).objects).toHaveLength(0);
  });

  it("replayed op ids are idempotent; re-importing the same file creates nothing new", async () => {
    const t = makeApp();
    const first = await start(t, "netscape_html", NETSCAPE_HTML, "b.html");
    await runImport(t.env, first.params, fakeStep(), { throttle: false });
    expect(t.sent).toHaveLength(3);

    const stub = t.env.LIBRARY.getByName(t.user);
    const before = await stub.exportItems();
    const op = { type: "item.add", opId: `${first.id}:0`, at: Date.now(), itemId: before[0]!.id, url: before[0]!.url, source: "import" };
    const r = await stub.applyOps(IMPORT_DEVICE_ID, [op]);
    expect(r.parseJobs).toHaveLength(0);
    expect(r.response.applied).toContain(op.opId);

    const second = await start(t, "netscape_html", NETSCAPE_HTML, "b.html");
    await runImport(t.env, second.params, fakeStep(), { throttle: false });
    expect(await stub.exportItems()).toHaveLength(3);
    expect(t.sent).toHaveLength(3);
    expect(await getJob(t.env.DB, t.user, second.id)).toMatchObject({ status: "done", total: 4, done: 4, skipped: 1 });
  });

  it("batches of 200 with throttle sleeps between batches", async () => {
    const t = makeApp();
    let csv = "title,url,time_added,tags,status\n";
    for (let i = 0; i < 450; i++) csv += `T${i},https://example.com/p/${i},${1700000000 + i},t${i % 3},unread\n`;
    const { id, params } = await start(t, "pocket_csv", csv, "big.csv");
    const step = fakeStep();
    await runImport(t.env, params, step, { throttle: true });
    expect(step.names.filter((n: string) => n.startsWith("apply-"))).toEqual(["apply-0", "apply-1", "apply-2"]);
    expect(step.names.filter((n: string) => n.startsWith("throttle-"))).toEqual(["throttle-0", "throttle-1"]);
    expect(await getJob(t.env.DB, t.user, id)).toMatchObject({ status: "done", total: 450, done: 450, skipped: 0 });
    expect(t.sent).toHaveLength(450);
    expect(t.sent[0]!.url).toBe("https://example.com/p/449"); // newest first
  });

  it("fails the job with a code for unparseable files", async () => {
    const t = makeApp();
    const { id, params } = await start(t, "pocket_csv", "foo,bar\n1,2\n", "x.csv");
    const out = await runImport(t.env, params, fakeStep(), { throttle: false });
    expect(out.status).toBe("failed");
    expect(await getJob(t.env.DB, t.user, id)).toMatchObject({ status: "failed", error: "missing_url_column" });
  });
});
