// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { pageHtmlForCapture } from "./save.ts";

const at = (url: string) => vi.stubGlobal("location", new URL(url));

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.innerHTML = "";
});

describe("pageHtmlForCapture", () => {
  it("strips scripts and styles", async () => {
    at("https://example.com/a");
    document.body.innerHTML = "<p>hi</p><script>x()</script><style>p{}</style>";
    const html = await pageHtmlForCapture();
    expect(html).toContain("<p>hi</p>");
    expect(html).not.toContain("x()");
    expect(html).not.toContain("sroka-reddit-json");
  });

  it("embeds the pruned Reddit thread JSON on a comment permalink", async () => {
    at("https://www.reddit.com/r/a/comments/1x/slug/c9/");
    const json = [{ kind: "Listing", data: { children: [{ kind: "t3", data: { title: "T</script>", secret_field: 1 } }] } }, { kind: "Listing", data: { children: [] } }];
    const fetch = vi.fn(async () => new Response(JSON.stringify(json)));
    vi.stubGlobal("fetch", fetch);
    const html = await pageHtmlForCapture();
    expect(fetch.mock.calls[0]![0]).toBe("/r/a/comments/1x/slug/c9.json?raw_json=1&limit=200&depth=8&context=3");
    const raw = /<script type="application\/json" id="sroka-reddit-json">([^<]*)<\/script>/.exec(html)?.[1];
    expect(JSON.parse(raw!)[0].data.children[0].data).toEqual({ title: "T</script>" });
  });

  it("captures the page without JSON when the fetch fails", async () => {
    at("https://www.reddit.com/r/a/comments/1x/slug/");
    vi.stubGlobal("fetch", vi.fn(async () => new Response("no", { status: 403 })));
    const html = await pageHtmlForCapture();
    expect(html).not.toContain("sroka-reddit-json");
  });
});
