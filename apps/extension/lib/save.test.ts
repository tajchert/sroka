import { beforeEach, describe, expect, it, vi } from "vitest";
import { saveTab } from "./save.ts";
import { setSettings } from "./settings.ts";
import { installChrome, jsonRes } from "./test-chrome.ts";

let c: ReturnType<typeof installChrome>;
let bodies: Record<string, unknown>[];
const page = (html: string) => c.scripting.executeScript.mockResolvedValue([{ result: html }] as never);
const tab = { id: 7, url: "https://medium.com/p/x", title: "X" };

beforeEach(async () => {
  c = installChrome();
  vi.restoreAllMocks();
  bodies = [];
  vi.spyOn(globalThis, "fetch").mockImplementation((async (_u: string, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)));
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
});
