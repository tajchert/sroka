import { describe, expect, it } from "vitest";
import { cleanByline, extractArticle } from "./extract.ts";

const p = (s: string, n: number) => `<p>${Array.from({ length: n }, (_, i) => `${s} sentence ${i}, with some commas, and more words.`).join(" ")}</p>`;

describe("extractArticle (Defuddle)", () => {
  it("picks the article over a longer legal disclaimer (apollo.com daily spark layout)", () => {
    const html = `<!doctype html><html><head><title>No Signs of AI Payoff</title></head><body>
      <header><nav>Home Insights</nav></header>
      <main><div class="blog-detail"><h1>No Signs of AI Payoff</h1>
        <div class="blog-detail-content">${p("Revenue per worker is rising for the Mag 7", 6)}${p("Profit margins are flat for the S&P 493", 6)}</div></div>
      <div data-cmp-is="accordion" role="region"><button>Disclaimer</button>
        <div>${p("This presentation may not be distributed", 12)}${p("Apollo makes no representation or warranty", 12)}</div></div></main>
      <footer>Footer links</footer></body></html>`;
    const ex = extractArticle(html, "https://www.apollo.com/x")!;
    expect(ex.text).toContain("Revenue per worker");
  });

  it("restores lazy-loaded images from attributes the extractor would drop", () => {
    const img = `<img width="1024" height="683" src="data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=" nitro-lazy-srcset="https://ex.com/a-1024.jpg 1024w, https://ex.com/a-300.jpg 300w">`;
    const img2 = `<img src="data:image/gif;base64,R0lGOD" data-lazy-src="https://ex.com/b.png">`;
    const html = `<!doctype html><html><body><article><h1>T</h1>${p("Body", 10)}<figure>${img}</figure>${p("More", 10)}<figure>${img2}</figure></article></body></html>`;
    const ex = extractArticle(html, "https://ex.com/post")!;
    expect(ex.contentHtml).toContain("https://ex.com/a-1024.jpg");
    expect(ex.contentHtml).toContain("https://ex.com/b.png");
  });

  it("cleanByline drops prefixes, URLs and blurbs", () => {
    expect(cleanByline("View all posts by Daniel Lemire")).toBe("Daniel Lemire");
    expect(cleanByline("By Jane Doe")).toBe("Jane Doe");
    expect(cleanByline("https://www.facebook.com/someone")).toBeNull();
    expect(cleanByline("x".repeat(101))).toBeNull();
    expect(cleanByline("Byron Smith")).toBe("Byron Smith");
  });
});
