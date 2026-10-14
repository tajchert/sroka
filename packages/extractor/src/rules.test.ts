import { describe, expect, it } from "vitest";
import { buildContent, detectBotWall, extractArticle } from "./index.ts";

const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
const PAGE = `<!doctype html><html lang="en"><head><title>Doc Title</title><meta property="og:title" content="OG Title">
<meta name="description" content="Desc"></head><body>
<div class="promo">PROMO ${para.repeat(30)}</div>
<article><h1>Hello</h1><p>${para.repeat(8)}</p><p class="ad">BUY NOW ${para}</p><p>${para.repeat(8)}</p></article>
<section id="real"><p>REAL CONTENT ${para.repeat(3)}</p></section>
</body></html>`;

describe("extractArticle options", () => {
  it("removeSelectors drops elements before extraction; invalid selectors are ignored", () => {
    const plain = extractArticle(PAGE, "https://example.com/a")!;
    expect(plain.text).toContain("BUY NOW");
    const ex = extractArticle(PAGE, "https://example.com/a", { removeSelectors: [".ad", "[[invalid", ".promo"] })!;
    expect(ex.text).not.toContain("BUY NOW");
    expect(ex.text).not.toContain("PROMO");
    expect(ex.text).toContain("quick brown fox");
  });

  it("contentSelector uses the matched element instead of Readability", () => {
    const ex = extractArticle(PAGE, "https://example.com/a", { contentSelector: "#real" })!;
    expect(ex.text.startsWith("REAL CONTENT")).toBe(true);
    expect(ex.text).not.toContain("BUY NOW");
    expect(ex.contentHtml).toContain("<p>REAL CONTENT");
    expect(ex.title).toBe("OG Title");
    expect(ex.excerpt).toBe("Desc");
    expect(ex.siteName).toBe("example.com");
  });

  it("contentSelector falls back to Readability when it matches nothing", () => {
    const ex = extractArticle(PAGE, "https://example.com/a", { contentSelector: "#nope" })!;
    expect(ex.text).toContain("quick brown fox");
  });

  it("minTextChars sets the partial threshold in buildContent", async () => {
    const opts = { url: "https://example.com/a", contentId: "c1", transform: async () => ({ bytes: new Uint8Array(), contentType: "image/webp" }), fetchOptions: {} };
    const html = `<html><body><article><p>${para.repeat(4)}</p></article></body></html>`; // ~360 chars
    const def = (await buildContent({ html, ...opts }))!;
    expect(def.status).toBe("partial");
    expect(def.textChars).toBeLessThan(500);
    const low = (await buildContent({ html, ...opts, extractOptions: { minTextChars: 100 } }))!;
    expect(low.status).toBe("ok");
    const pre = extractArticle(PAGE, "https://example.com/a", { contentSelector: "#real" })!;
    const fromPre = (await buildContent({ html: "<html></html>", ...opts, extracted: pre }))!;
    expect(new TextDecoder().decode(fromPre.files.find((f) => f.path === "text.txt")!.bytes)).toMatch(/^REAL CONTENT/);
  });
});

describe("detectBotWall", () => {
  it("detects Cloudflare / Akamai challenges", () => {
    expect(detectBotWall(`<html><head><title>Just a moment...</title></head><body><script src="/cdn-cgi/challenge-platform/h/b/orchestrate/x"></script></body></html>`)).toBe("challenge");
    expect(detectBotWall(`<html><head><title>Access Denied</title></head><body>You don't have permission. Reference #18.abc https://errors.edgesuite.net/18.abc</body></html>`)).toBe("challenge");
  });
  it("detects JS-only shells but not articles mentioning JavaScript", () => {
    expect(detectBotWall(`<html><body><noscript>You need to enable JavaScript to run this app.</noscript><div id="root"></div></body></html>`)).toBe("js_required");
    expect(detectBotWall(`<html><body><noscript>Please enable JavaScript</noscript><article>${para.repeat(30)}</article></body></html>`)).toBeNull();
    expect(detectBotWall(`<html><body><p>${para}</p></body></html>`)).toBeNull();
  });
});
