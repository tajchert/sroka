import { describe, expect, it, vi } from "vitest";

// Defuddle finding (almost) nothing must fall back to Readability.
vi.mock("defuddle", () => ({ default: class { parse() { return { content: "<p>tiny</p>", title: "", author: "", site: "", published: "", description: "", image: "", language: "" }; } } }));
const { extractArticle } = await import("./extract.ts");

describe("extractArticle fallback", () => {
  it("uses Readability when Defuddle's text is shorter", () => {
    const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
    const html = `<!doctype html><html><head><title>T</title></head><body><article><h1>T</h1><p>${para.repeat(12)}</p></article></body></html>`;
    const ex = extractArticle(html, "https://example.com/a")!;
    expect(ex.text).toContain("quick brown fox");
    expect(ex.text.length).toBeGreaterThan(500);
  });
});
