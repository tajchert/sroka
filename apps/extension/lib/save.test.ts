import { beforeEach, describe, expect, it, vi } from "vitest";
import { saveTab } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes, requestJson } from "./test-chrome.ts";

let c: ReturnType<typeof installChrome>;
let bodies: Record<string, unknown>[];
const page = (html: string) => c.scripting.executeScript.mockResolvedValue([{ result: html }] as never);
const tab = { id: 7, url: "https://medium.com/p/x", title: "X" };

beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  bodies = [];
  vi.spyOn(globalThis, "fetch").mockImplementation((async (_u: string, init?: RequestInit) => {
    bodies.push(await requestJson(init));
    return jsonRes(202, { item: { id: "i1" }, created: true });
  }) as never);
  await setSettings({ token: "t", signedOut: false, captureHtml: false });
});

describe("saveTab html capture", () => {
  it("free page with capture off: URL only", async () => {
    page("<html><body><p>Free</p></body></html>");
    expect((await saveTab(tab)).ok).toBe(true);
    expect(bodies[0]).not.toHaveProperty("html");
  });
  it("paywalled page: sends the rendered html even with capture off", async () => {
    const html = "<html><body><span>Member-only story</span><p>Full text</p></body></html>";
    page(html);
    await saveTab(tab);
    expect(bodies[0]).toMatchObject({ url: tab.url, html, source: "extension" });
  });
  it("reddit: sends the rendered html even with capture off (Reddit blocks server fetches)", async () => {
    const html = "<html><body><shreddit-post post-title=\"Q\"></shreddit-post></body></html>";
    page(html);
    await saveTab({ id: 7, url: "https://www.reddit.com/r/AskReddit/comments/1/q/", title: "Q" });
    expect(bodies[0]).toMatchObject({ html });
  });
  it("capture on: always sends html", async () => {
    await setSettings({ captureHtml: true });
    page("<html><body><p>Free</p></body></html>");
    await saveTab(tab);
    expect(bodies[0]).toHaveProperty("html");
  });
  it("capture is on by default", async () => {
    delete c.storage.local.data.captureHtml;
    page("<html><body><p>Free</p></body></html>");
    await saveTab(tab);
    expect(bodies[0]).toHaveProperty("html");
  });
  it("sends captured html gzipped", async () => {
    await setSettings({ captureHtml: true });
    page("<html><body><p>Free</p></body></html>");
    await saveTab(tab);
    const init = vi.mocked(globalThis.fetch).mock.calls[0]![1]!;
    expect((init.headers as Record<string, string>)["content-encoding"]).toBe("gzip");
    expect(init.body).toBeInstanceOf(ArrayBuffer);
  });
});

describe("saveTab forceCapture (re-save)", () => {
  it("sends the rendered html even with capture off and a free page", async () => {
    page("<html><body><p>Full text after sign-in</p></body></html>");
    expect((await saveTab(tab, { forceCapture: true })).ok).toBe(true);
    expect(String(bodies[0]?.html)).toContain("Full text after sign-in");
  });
  it("does not save at all when the page cannot be captured", async () => {
    c.scripting.executeScript.mockRejectedValue(new Error("restricted") as never);
    const r = await saveTab(tab, { forceCapture: true });
    expect(r.ok).toBe(false);
    expect(bodies).toHaveLength(0);
  });
});
