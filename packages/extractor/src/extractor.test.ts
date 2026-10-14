import { unzipSync, strFromU8 } from "fflate";
import { describe, expect, it, vi } from "vitest";
import { PackageManifest } from "@sroka/shared";
import {
  assertFetchable,
  buildContent,
  countWords,
  decodeHtml,
  extractArticle,
  FetchError,
  isBlockedHost,
  processImages,
  rewriteImages,
  safeFetch,
  sanitizeArticle,
} from "./index.ts";

const para = "The quick brown fox jumps over the lazy dog while reading a long and interesting article. ";
const ARTICLE = `<!doctype html><html lang="en"><head><title>Hello World - Site</title>
<meta property="og:site_name" content="Example Site"><meta property="og:image" content="/lead.jpg">
<meta property="article:published_time" content="2026-01-02T03:04:05Z">
<script>window.evil = 1</script></head><body>
<nav><a href="/">Home</a></nav>
<article><h1>Hello World</h1><p class="byline">By Jane Doe</p>
<p>${para.repeat(8)}</p>
<p><img src="/img/a.png" srcset="/img/a-small.png 400w, /img/a-big.png 1200w" alt="A"></p>
<p>${para.repeat(8)} <a href="/relative">link</a></p>
<p><img src="https://tracker.example.net/p.gif" width="1" height="1"></p>
<iframe src="https://www.youtube.com/embed/xyz"></iframe>
<script>alert(1)</script>
<p>${para.repeat(8)}</p></article><footer>foot</footer></body></html>`;

describe("ssrf", () => {
  const blocked = [
    "http://localhost/", "http://foo.localhost/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/",
    "http://10.1.2.3/", "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/", "http://169.254.169.254/latest/meta-data",
    "http://100.64.0.1/", "http://0.0.0.0/", "http://[::1]/", "http://[::]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/",
    "http://[::ffff:169.254.169.254]/", "http://[fc00::1]/", "http://[fd12:3456::1]/", "http://[fe80::1]/", "http://[64:ff9b::7f00:1]/",
    "http://[2002:7f00:1::]/", "http://printer/", "http://x.internal/", "http://nas.local/", "http://localhost./",
  ];
  for (const u of blocked) it(`blocks ${u}`, () => expect(() => assertFetchable(u)).toThrow());
  for (const u of ["ftp://example.com/", "file:///etc/passwd", "javascript:alert(1)", "gopher://example.com", "http://user:pw@example.com/"])
    it(`rejects ${u}`, () => expect(() => assertFetchable(u)).toThrow());
  it("allows public hosts", () => {
    for (const u of ["https://example.com/a", "http://8.8.8.8/", "http://[2606:4700::1111]/", "https://sub.example.co.uk:8443/"]) expect(() => assertFetchable(u)).not.toThrow();
  });
  it("blocks own hosts and subdomains", () => {
    expect(isBlockedHost("sroka.app", ["sroka.app"])).toBe(true);
    expect(isBlockedHost("c.sroka.app", ["sroka.app"])).toBe(true);
    expect(isBlockedHost("notsroka.app", ["sroka.app"])).toBe(false);
  });
});

function resp(body: BodyInit | null, init: ResponseInit = {}) {
  return new Response(body, { headers: { "content-type": "text/html" }, ...init });
}

describe("safeFetch", () => {
  it("fetches html and reports final url", async () => {
    const f = vi.fn(async () => resp("<p>hi</p>"));
    const r = await safeFetch("https://example.com/a", { fetch: f as never });
    expect(r.kind).toBe("html");
    expect(new TextDecoder().decode(r.bytes)).toBe("<p>hi</p>");
    expect(r.url).toBe("https://example.com/a");
  });
  it("follows redirects manually and re-validates each hop", async () => {
    const f = vi.fn(async (u: string) => {
      if (u === "https://a.com/") return new Response(null, { status: 302, headers: { location: "https://b.com/x" } });
      if (u === "https://b.com/x") return new Response(null, { status: 301, headers: { location: "http://169.254.169.254/" } });
      return resp("secret");
    });
    await expect(safeFetch("https://a.com/", { fetch: f as never })).rejects.toMatchObject({ code: "blocked_url" });
    expect(f).toHaveBeenCalledTimes(2);
  });
  it("resolves relative redirects and tracks final url", async () => {
    const f = vi.fn(async (u: string) =>
      u === "https://a.com/start" ? new Response(null, { status: 302, headers: { location: "/final" } }) : resp("ok"),
    );
    const r = await safeFetch("https://a.com/start", { fetch: f as never });
    expect(r.url).toBe("https://a.com/final");
    expect(r.redirects).toBe(1);
  });
  it("caps redirects at 5", async () => {
    const f = vi.fn(async (u: string) => new Response(null, { status: 302, headers: { location: u + "x" } }));
    await expect(safeFetch("https://a.com/", { fetch: f as never })).rejects.toMatchObject({ code: "too_many_redirects" });
    expect(f).toHaveBeenCalledTimes(6);
  });
  it("blocks private initial urls without fetching", async () => {
    const f = vi.fn();
    await expect(safeFetch("http://127.0.0.1:8787/", { fetch: f as never })).rejects.toMatchObject({ code: "blocked_url" });
    expect(f).not.toHaveBeenCalled();
  });
  it("enforces size cap by content-length and by streaming", async () => {
    const big = new Uint8Array(2000);
    await expect(
      safeFetch("https://a.com/", { maxBytes: 1000, fetch: (async () => resp(big, { headers: { "content-type": "text/html", "content-length": "2000" } })) as never }),
    ).rejects.toMatchObject({ code: "too_large" });
    await expect(safeFetch("https://a.com/", { maxBytes: 1000, fetch: (async () => resp(big)) as never })).rejects.toMatchObject({ code: "too_large" });
  });
  it("rejects non-html by default, allows when asked", async () => {
    const f = (async () => new Response("%PDF", { headers: { "content-type": "application/pdf" } })) as never;
    await expect(safeFetch("https://a.com/x.pdf", { fetch: f })).rejects.toMatchObject({ code: "not_html" });
    const r = await safeFetch("https://a.com/x.pdf", { fetch: f, allow: ["pdf"] });
    expect(r.kind).toBe("pdf");
  });
  it("classifies http errors", async () => {
    const mk = (s: number) => safeFetch("https://a.com/", { fetch: (async () => new Response("x", { status: s })) as never });
    await expect(mk(404)).rejects.toMatchObject({ code: "http_404", transient: false });
    await expect(mk(503)).rejects.toMatchObject({ code: "http_503", transient: true });
    await expect(mk(429)).rejects.toMatchObject({ code: "http_429", transient: true });
  });
  it("times out", async () => {
    const f = (async (_u: string, init: RequestInit) =>
      new Promise((_res, rej) => init.signal!.addEventListener("abort", () => rej(new Error("aborted"))))) as never;
    const err = (await safeFetch("https://a.com/", { fetch: f, timeoutMs: 30 }).catch((e) => e)) as FetchError;
    expect(err.code).toBe("timeout");
    expect(err.transient).toBe(true);
  });
  it("times out during body streaming", async () => {
    const stream = new ReadableStream({ start() {} });
    const f = (async () => resp(stream)) as never;
    const err = (await safeFetch("https://a.com/", { fetch: f, timeoutMs: 30 }).catch((e) => e)) as FetchError;
    expect(err.transient).toBe(true);
  });
  it("decodes charset", () => {
    const latin = new Uint8Array([0x63, 0x61, 0x66, 0xe9]);
    expect(decodeHtml(latin, "text/html; charset=iso-8859-1")).toBe("café");
    expect(decodeHtml(new TextEncoder().encode("<meta charset=utf-8>é"))).toContain("é");
  });
});

describe("extractArticle", () => {
  const ex = extractArticle(ARTICLE, "https://example.com/post/1")!;
  it("extracts metadata", () => {
    expect(ex).toBeTruthy();
    expect(ex.title).toContain("Hello World");
    expect(ex.siteName).toBe("Example Site");
    expect(ex.lang).toBe("en");
    expect(ex.byline).toContain("Jane Doe");
    expect(ex.publishedTime).toBe("2026-01-02T03:04:05Z");
    expect(ex.leadImage).toBe("https://example.com/lead.jpg");
    expect(ex.text).toContain("quick brown fox");
    expect(ex.contentHtml).not.toContain("window.evil");
    expect(ex.excerpt).toBeTruthy();
  });
  it("falls back siteName to host", () => {
    const e = extractArticle(`<html><body><article><p>${para.repeat(10)}</p></article></body></html>`, "https://www.foo.org/x")!;
    expect(e.siteName).toBe("foo.org");
  });
  it("returns null for empty pages", () => {
    expect(extractArticle("<html><body></body></html>", "https://a.com/")).toBeNull();
    expect(extractArticle("<html><body><p>hi</p></body></html>", "https://a.com/")).toBeNull();
  });
  it("counts words", () => {
    expect(countWords("one two  three")).toBe(3);
    expect(countWords("")).toBe(0);
  });
});

describe("sanitizeArticle", () => {
  const S = (h: string) => sanitizeArticle(h, "https://example.com/dir/page");
  it("absolutizes links and images, picks best srcset, drops srcset attr", () => {
    const r = S(`<p><a href="../x">x</a><img src="a.png" srcset="a1.png 100w, a2.png 900w"></p><img srcset="s1.png 100w, s2.png 800w">`);
    expect(r.html).toContain('href="https://example.com/x"');
    expect(r.html).toContain('src="https://example.com/dir/a.png"');
    expect(r.html).toContain('src="https://example.com/dir/s2.png"');
    expect(r.html).not.toContain("srcset");
    expect(r.images).toEqual(["https://example.com/dir/a.png", "https://example.com/dir/s2.png"]);
  });
  it("uses lazy-load attributes instead of data: placeholders", () => {
    const r = S(`<img src="data:image/gif;base64,R0lGOD" data-src="/real.jpg">`);
    expect(r.images).toEqual(["https://example.com/real.jpg"]);
  });
  const xss = [
    `<a href="javascript:alert(1)">x</a>`,
    `<a href=" jAvAsCrIpT:alert(1)">x</a>`,
    `<a href="data:text/html,<script>alert(1)</script>">x</a>`,
    `<a href="vbscript:x">x</a>`,
    `<img src="x" onerror="alert(1)">`,
    `<img src=x onload=alert(1)>`,
    `<svg onload="alert(1)"><script>alert(2)</script><circle/></svg>`,
    `<svg><a xlink:href="javascript:alert(1)"><text>x</text></a></svg>`,
    `<script>alert(1)</script>`,
    `<style>body{background:url(javascript:alert(1))}</style>`,
    `<form action="/x"><input name=a><button>go</button></form>`,
    `<p onclick="alert(1)" style="x" id="y">t</p>`,
    `<object data="x"></object><embed src="x">`,
    `<math><mi xlink:href="javascript:alert(1)">x</mi></math>`,
    `<noscript><img src=x onerror=alert(1)></noscript>`,
    `<a href="//evil.com/x" onmouseover="alert(1)">x</a>`,
    `<video src="x" autoplay onerror="alert(1)"></video>`,
    `<link rel=stylesheet href="https://evil.com/x.css"><meta http-equiv=refresh content="0;url=javascript:alert(1)">`,
  ];
  for (const [i, x] of xss.entries())
    it(`neutralizes xss #${i}`, () => {
      const out = S(`<p>safe</p>${x}`).html.toLowerCase();
      for (const bad of ["javascript:", "vbscript:", "onerror", "onload", "onclick", "onmouseover", "<script", "<style", "<form", "<input", "<svg", "<object", "<embed", "<link", "<meta", "data:text", "srcset", "autoplay"])
        expect(out, `${bad} in ${out}`).not.toContain(bad);
      expect(out).toContain("safe");
    });
  it("protocol-relative links resolve to https only via base and never keep // form", () => {
    const out = S(`<a href="//evil.com/x">x</a>`).html;
    expect(out).toContain('href="https://evil.com/x"');
  });
  it("drops tracking pixels (1x1, tracker hosts)", () => {
    const r = S(`<img src="https://x.com/a.gif" width="1" height="1"><img src="https://www.google-analytics.com/collect?v=1"><img src="https://pixel.wp.com/g.gif"><img src="https://ok.com/real.jpg" width="600" height="400">`);
    expect(r.images).toEqual(["https://ok.com/real.jpg"]);
  });
  it("turns iframes into link cards", () => {
    const r = S(`<iframe src="https://www.youtube.com/embed/abc" width="560"></iframe><iframe src="javascript:alert(1)"></iframe>`);
    expect(r.html).toContain('<a href="https://www.youtube.com/embed/abc"');
    expect(r.html).toContain("embed-card");
    expect(r.html).not.toContain("<iframe");
    expect(r.html).not.toContain("javascript:");
  });
  it("embed link cards carry rel and target", () => {
    const r = S(`<iframe src="https://www.youtube.com/embed/abc"></iframe>`);
    expect(r.html).toContain('rel="noopener noreferrer nofollow"');
    expect(r.html).toContain('target="_blank"');
  });
  it("adds rel/target to external links", () => {
    expect(S(`<a href="https://a.com/">x</a>`).html).toContain('rel="noopener noreferrer nofollow"');
  });
  it("rewriteImages swaps and drops", () => {
    const r = S(`<img src="https://a.com/1.png?x=1&y=2"><img src="https://a.com/2.png">`);
    const out = rewriteImages(r.html, (u) => (u.includes("1.png") ? "img/abc.webp" : null));
    expect(out).toBe('<img src="img/abc.webp" />');
  });
});

describe("buildContent", () => {
  const png = new Uint8Array([1, 2, 3, 4]);
  const imgFetch = (async (u: string) => {
    if (u.includes("tracker")) throw new Error("should not fetch");
    if (u.endsWith("/missing.png")) return new Response("nope", { status: 404 });
    return new Response(png, { headers: { "content-type": "image/png" } });
  }) as never;
  const transform = async (b: Uint8Array, _t: string, o: { width: number }) => ({ bytes: new Uint8Array([...b, o.width & 255, o.width >> 8]), contentType: "image/webp" });

  it("produces article.html, text.txt, images, thumb and a valid package", async () => {
    const r = (await buildContent({
      html: ARTICLE,
      url: "https://example.com/post/1",
      contentId: "0192f3c4-1111-7000-8000-000000000001",
      transform,
      fetchOptions: { fetch: imgFetch },
    }))!;
    expect(r.status).toBe("ok");
    expect(r.meta.wordCount).toBeGreaterThan(100);
    expect(r.meta.readingMinutes).toBe(Math.max(1, Math.round(r.meta.wordCount / 230)));
    const byPath = new Map(r.files.map((f) => [f.path, f]));
    const html = new TextDecoder().decode(byPath.get("article.html")!.bytes);
    expect(html).toMatch(/<html lang="en">/);
    expect(html).toMatch(/<img src="img\/[0-9a-f]{64}\.webp"/);
    expect(html).not.toMatch(/https?:\/\/[^"]*\.(png|jpg)/);
    expect(html).not.toContain("<script");
    expect(html).toContain("embed-card");
    expect(byPath.get("text.txt")).toBeTruthy();
    expect(r.leadImageKey).toBe("thumb.webp");
    expect(byPath.get("thumb.webp")!.bytes.at(-2)).toBe(400 & 255);
    const imgPaths = r.files.filter((f) => f.path.startsWith("img/"));
    expect(imgPaths.length).toBe(1);

    const zip = unzipSync(byPath.get("package.zip")!.bytes);
    expect(Object.keys(zip).sort()).toEqual(["article.html", imgPaths[0]!.path, "manifest.json"].sort());
    const manifest = PackageManifest.parse(JSON.parse(strFromU8(zip["manifest.json"]!)));
    expect(manifest.files.map((f) => f.path)).toContain("article.html");
    expect(manifest.wordCount).toBe(r.meta.wordCount);
  });

  it("stores image entries uncompressed in the zip", async () => {
    const r = (await buildContent({ html: ARTICLE, url: "https://example.com/post/1", contentId: "0192f3c4-1111-7000-8000-000000000001", transform, fetchOptions: { fetch: imgFetch } }))!;
    const zipBytes = r.files.find((f) => f.path === "package.zip")!.bytes;
    // central directory: compression method (offset 10 in each header) 0 = stored for the image, 8 for others
    const dv = new DataView(zipBytes.buffer, zipBytes.byteOffset, zipBytes.byteLength);
    const methods: Record<string, number> = {};
    for (let i = 0; i < zipBytes.length - 46; i++) {
      if (dv.getUint32(i, true) === 0x02014b50) {
        const nameLen = dv.getUint16(i + 28, true);
        methods[new TextDecoder().decode(zipBytes.subarray(i + 46, i + 46 + nameLen))] = dv.getUint16(i + 10, true);
      }
    }
    const imgName = Object.keys(methods).find((n) => n.startsWith("img/"))!;
    expect(methods[imgName]).toBe(0);
    expect(methods["article.html"]).toBe(8);
  });

  it("falls back to the original image when transform fails; drops images that fail to download", async () => {
    const html = ARTICLE.replace("</article>", `<p><img src="/missing.png"></p></article>`);
    const r = (await buildContent({
      html, url: "https://example.com/post/1", contentId: "0192f3c4-1111-7000-8000-000000000001",
      transform: async () => { throw new Error("images down"); },
      fetchOptions: { fetch: imgFetch },
    }))!;
    const img = r.files.find((f) => f.path.startsWith("img/"))!;
    expect(img.path).toMatch(/\.png$/);
    expect(img.contentType).toBe("image/png");
    expect(r.leadImageKey).toBeUndefined();
    const out = new TextDecoder().decode(r.files.find((f) => f.path === "article.html")!.bytes);
    expect(out).not.toContain("missing.png");
  });

  it("caps images at 50", async () => {
    const imgs = Array.from({ length: 60 }, (_, i) => `<p><img src="/i/${i}.png"></p>`).join("");
    const f = (async (u: string) => new Response(new TextEncoder().encode(u), { headers: { "content-type": "image/png" } })) as never;
    const r = (await buildContent({
      html: `<html><body><article><p>${para.repeat(10)}</p>${imgs}</article></body></html>`,
      url: "https://example.com/p", contentId: "0192f3c4-1111-7000-8000-000000000001", transform, fetchOptions: { fetch: f },
    }))!;
    expect(r.files.filter((x) => x.path.startsWith("img/")).length).toBe(50);
  });

  it("stops storing images once the byte budget is reached", async () => {
    const f = (async () => new Response(new Uint8Array(100).fill(7), { headers: { "content-type": "image/png" } })) as never;
    let n = 0;
    const tr = async () => ({ bytes: new Uint8Array(100).fill(++n), contentType: "image/webp" });
    const r = await processImages({ urls: ["https://a.com/1.png", "https://a.com/2.png", "https://a.com/3.png"], leadCandidates: [], transform: tr, fetchOptions: { fetch: f }, maxTotalBytes: 250, concurrency: 1 });
    expect(r.files.length).toBe(2);
  });

  it("lower-priority lead candidate finishing last does not overwrite the thumbnail", async () => {
    const f = (async (u: string) => new Response(new Uint8Array([u.includes("og") ? 1 : 2]), { headers: { "content-type": "image/png" } })) as never;
    const tr = async (b: Uint8Array) => {
      if (b[0] === 2) await new Promise((r) => setTimeout(r, 30)); // lower-priority candidate finishes last
      return { bytes: new Uint8Array([b[0]!]), contentType: "image/webp" };
    };
    const r = await processImages({ urls: ["https://a.com/b.png"], leadCandidates: ["https://a.com/og.png", "https://a.com/b.png"], transform: tr, fetchOptions: { fetch: f }, concurrency: 2 });
    expect(Array.from(r.thumb!)).toEqual([1]);
  });

  it("returns null when nothing is extractable", async () => {
    expect(await buildContent({ html: "<html><body></body></html>", url: "https://a.com/", contentId: "x", transform, fetchOptions: {} })).toBeNull();
  });
});
