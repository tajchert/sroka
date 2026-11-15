// Generates the Chrome Web Store images into store/chrome-web-store/images/.
//
// Real UI, mocked data: it serves the BUILT extension (apps/extension/.output/chrome-mv3) and the BUILT web app
// (apps/web/dist) from local static servers, stubs `chrome.*` and the /v1 API with made-up sample articles, captures
// the real popup / options page / library / reader in headless Chromium, and composes 1280x800 marketing frames.
//
// Not a project dependency. Run from the repo root after `npm run build -w @sroka/extension -w @sroka/web`:
//   PW_CORE=/path/to/node_modules/playwright-core node store/scripts/chrome-images.mjs
// (install once anywhere with `npm i playwright-core`; Chromium comes from ~/Library/Caches/ms-playwright
//  or set CHROME=/path/to/chrome).
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { homedir } from "node:os";

const root = new URL("../../", import.meta.url).pathname;
const out = join(root, "store/chrome-web-store/images");
mkdirSync(out, { recursive: true });
const { chromium } = createRequire(import.meta.url)(process.env.PW_CORE || "playwright-core");
const chromePath =
  process.env.CHROME ||
  join(homedir(), "Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");

// ---------- sample data (all made up) ----------
const NOW = Date.now();
const H = 3600e3;
const PALETTES = [
  ["#1e6f8f", "#7cc0da", "#f2c84b"],
  ["#5b4b8a", "#b9a8e8", "#f2c84b"],
  ["#2f7d5b", "#9ad7b8", "#f6efe0"],
  ["#b5532f", "#f0b48f", "#15171c"],
  ["#2a3a5c", "#8fa8d8", "#f2c84b"],
  ["#8a6d1f", "#f2d88a", "#1e6f8f"],
];
const lead = (i) => {
  const [a, b, c] = PALETTES[i % PALETTES.length];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 120"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="160" height="120" fill="url(#g)"/><circle cx="${40 + (i * 23) % 80}" cy="40" r="22" fill="${c}" opacity=".85"/><path d="M0 120 L50 70 L90 100 L120 60 L160 110 V120Z" fill="#15171c" opacity=".35"/></svg>`;
  return "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");
};
const ARTICLES = [
  ["The Quiet Craft of Bookbinding", "Threadbare Journal", "Edda Marlowe", 9, ["craft", "long reads"]],
  ["Why Tide Pools Are Nature’s Little Laboratories", "Shoreline Notes", "Rune Calloway", 7, ["nature"]],
  ["A Beginner’s Guide to Sourdough Starters", "Crumb & Crust", "Pia Anselm", 6, ["food", "how-to"]],
  ["How Small Libraries Survive the Winter", "Hearth Quarterly", "Tobias Wren", 12, ["long reads"]],
  ["Notes on Building a Slower Calendar", "Margin Weekly", "Ines Okafor", 5, ["productivity"]],
  ["The Long History of the Humble Lighthouse", "Beacon Review", "Callum Hart", 14, ["history", "long reads"]],
  ["Mapping the Night Sky From a Balcony", "Starlit Field Guide", "Mira Solheim", 8, ["nature", "how-to"]],
  ["What Moss Teaches About Patience", "Understory", "Jonas Birch", 4, ["nature"]],
];
const uid = (n) => `0198a000-0000-7000-8000-${String(n).padStart(12, "0")}`;
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
const mkItem = (i, over = {}) => {
  const [title, site, author, min, tags] = ARTICLES[i];
  const host = slug(site).replace(/-/g, "") + ".example";
  const url = `https://${host}/${slug(title)}`;
  return {
    id: uid(i + 1), url, canonicalUrl: url, title, excerpt: `${title.split(" ").slice(0, 3).join(" ")}… a slow, careful look at the details most people miss, and why they matter.`,
    siteName: site, author, lang: "en", leadImageUrl: lead(i), leadImageKey: "thumb.webp", wordCount: min * 230, readingMinutes: min,
    contentId: uid(100 + i), contentPrivate: false, parseStatus: "ok", parseError: null, status: "unread", isFavorite: i === 1,
    progress: i === 3 ? 0.35 : 0, progressAnchor: null, savedAt: NOW - (i * 5 + 1) * H, archivedAt: null, lastReadAt: null,
    source: "extension", tags, kind: "article", fileName: null, fileSize: null, seq: i + 1, ...over,
  };
};
const ITEMS = ARTICLES.map((_, i) => mkItem(i));
const TAGS = ["craft", "food", "history", "how-to", "long reads", "nature", "productivity"].map((name, i) => ({
  id: uid(200 + i), name, count: ITEMS.filter((it) => it.tags.includes(name)).length, seq: i + 1,
}));

const articleHtml = (it) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${it.title}</title></head><body><article>
<h1>${it.title}</h1><p class="byline">${it.author} · ${it.siteName}</p>
<p>There is a particular kind of attention that only shows up when nothing else is asking for it. You notice it on slow mornings, on long train rides, in the hour after the kettle has gone quiet. This piece is about that attention, and about the small crafts that quietly train it.</p>
<p>Most of what we read arrives in a rush, between meetings and notifications, and leaves just as quickly. The articles worth keeping are rarely the loudest ones. They are the ones that reward a second paragraph, then a third, and that still make sense a week after you first set them aside.</p>
<h2>Start with the smallest unit</h2>
<p>Every long project begins with a single, unglamorous step: gathering the materials, folding the first sheet, feeding the starter. People who stick with a practice tend to describe it the same way. It stopped feeling like a task once it became a place they could return to.</p>
<p>That is also why saving something for later works so well. The page you keep is a small promise to your future self, and a calm, uncluttered reading view makes that promise easy to keep.</p>
<p>When the time comes, the text is simply there: no banners, no autoplay, no ten tabs competing for the same few minutes. Just the words, in a size and a width that your eyes can settle into.</p>
<h2>What to remember</h2>
<p>Choose less. Return often. Let the good things take the time they take. The rest, as they say, can wait in the queue.</p>
</article></body></html>`;

// ---------- static servers ----------
const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml", ".json": "application/json", ".webmanifest": "application/json" };
const serve = (dir, { spa = false, extra } = {}) =>
  new Promise((resolve) => {
    const s = createServer((req, res) => {
      const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (extra) { const r = extra(p); if (r) { res.writeHead(200, { "content-type": "text/html; charset=utf-8", "access-control-allow-origin": "*" }); return res.end(r); } }
      let f = normalize(join(dir, p));
      if (!f.startsWith(dir)) { res.writeHead(403); return res.end(); }
      if (existsSync(f) && statSync(f).isDirectory()) f = join(f, "index.html");
      if (!existsSync(f) && spa) f = join(dir, "app/index.html");
      if (!existsSync(f)) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
      res.end(readFileSync(f));
    }).listen(0, "127.0.0.1", () => resolve({ s, origin: `http://127.0.0.1:${s.address().port}` }));
  });
const ext = await serve(join(root, "apps/extension/.output/chrome-mv3"));
const web = await serve(join(root, "apps/web/dist"), {
  spa: true,
  extra: (p) => { const m = p.match(/^\/__c\/(\d+)\/article\.html$/); return m ? articleHtml(ITEMS[Number(m[1])]) : null; },
});

const browser = await chromium.launch({ executablePath: chromePath, headless: true });
const json = (route, body, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

// ---------- extension: chrome.* stub ----------
const CHROME_STUB = (state) => `(() => {
  const S = ${JSON.stringify(state)};
  const mk = (data) => ({
    get: async (k) => { if (k == null) return { ...data }; const ks = typeof k === "string" ? [k] : Array.isArray(k) ? k : Object.keys(k); const r = {}; for (const x of ks) if (x in data) r[x] = data[x]; return r; },
    set: async (o) => { Object.assign(data, o); }, remove: async (k) => { for (const x of [].concat(k)) delete data[x]; },
  });
  window.close = () => {};
  window.chrome = {
    storage: { local: mk({ ...S.local }), session: mk({}) },
    tabs: { query: async () => [S.tab], create: async () => {} },
    runtime: { sendMessage: async (m) => (m.type === "save-tab" ? { ok: true, created: true, item: S.item } : { ok: true }), getManifest: () => ({ version: "0.6.0" }), id: "stub" },
    commands: { getAll: async () => [{ name: "_execute_action", shortcut: "Alt+Shift+S" }] },
    permissions: { contains: async () => true, request: async () => true },
    alarms: { create() {}, clear: async () => true, onAlarm: { addListener() {} } },
  };
})();`;
const apiMock = async (ctx) => {
  await ctx.route("https://api.sroka.app/**", (route) => {
    const u = new URL(route.request().url());
    if (u.pathname === "/v1/tags") return json(route, { tags: TAGS });
    if (u.pathname === "/v1/tags/suggestions") return json(route, { recent: ["long reads", "craft", "nature"], frequent: ["how-to", "food"], current: ["craft", "long reads"] });
    if (u.pathname.startsWith("/v1/items/")) return json(route, { item: { ...ITEMS[0], isFavorite: true } });
    return json(route, {});
  });
  await ctx.route("https://fonts.googleapis.com/**", (r) => r.continue());
};

const SIGNED_IN = { token: "demo", email: "reader@example.com", signedOut: false, serverUrl: "https://api.sroka.app", captureHtml: true, "sroka.hasSaved.v1": true };
const hero = { ...ITEMS[0], isFavorite: true };

async function capturePopup(tags) {
  const ctx = await browser.newContext({ viewport: { width: 420, height: 640 }, deviceScaleFactor: 2 });
  await apiMock(ctx);
  await ctx.addInitScript(CHROME_STUB({ local: SIGNED_IN, tab: { id: 1, url: hero.url, title: hero.title }, item: hero }));
  const page = await ctx.newPage();
  await page.goto(ext.origin + "/popup.html");
  await page.waitForSelector(".item-title");
  await page.waitForTimeout(800);
  if (tags) {
    await page.locator(".chip-add").click();
    await page.waitForSelector(".back");
    await page.waitForTimeout(500);
  }
  const png = await page.locator(".popup-card").screenshot();
  await ctx.close();
  return png;
}

async function captureOptions() {
  const ctx = await browser.newContext({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
  await apiMock(ctx);
  await ctx.addInitScript(CHROME_STUB({ local: SIGNED_IN, tab: {}, item: hero }));
  const page = await ctx.newPage();
  await page.goto(ext.origin + "/options.html");
  await page.waitForSelector(".page");
  await page.waitForTimeout(800);
  const box = await page.locator(".page").boundingBox();
  const png = await page.screenshot({ clip: { x: 0, y: 0, width: 760, height: Math.min(900, Math.ceil(box.y + box.height + 24)) } });
  await ctx.close();
  return png;
}

async function webPage(path, { width = 1180, height = 700 } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, colorScheme: "light" });
  await ctx.route("https://fonts.googleapis.com/**", (r) => r.continue());
  await ctx.route(web.origin + "/v1/**", (route) => {
    const u = new URL(route.request().url());
    const m = u.pathname.match(/^\/v1\/items\/([^/]+)(\/content)?$/);
    if (u.pathname === "/v1/me")
      return json(route, { user: { id: "u1", email: "reader@example.com", name: null, emailVerified: true, createdAt: NOW - 90 * 24 * H }, stats: { unread: ITEMS.length, archived: 12, favorites: 1, tags: TAGS.length }, clients: { extension: true, android: true } });
    if (u.pathname === "/v1/config") return json(route, { appOrigin: web.origin, minVersions: { android: null, ios: null, extension: null }, features: {}, limits: { maxOpsPerPush: 100, maxHtmlBytes: 5e6, maxImportBytes: 5e7 } });
    if (u.pathname === "/v1/tags") return json(route, { tags: TAGS });
    if (u.pathname === "/v1/items") return json(route, { items: ITEMS, nextCursor: null });
    if (m && m[2]) {
      const n = ITEMS.findIndex((x) => x.id === m[1]);
      return json(route, { articleUrl: `${web.origin}/__c/${n}/article.html`, baseUrl: `${web.origin}/__c/${n}/`, packageUrl: `${web.origin}/__c/${n}/p.zip`, documentUrl: null, expiresAt: NOW + 24 * H });
    }
    if (m) return json(route, { item: ITEMS.find((x) => x.id === m[1]) });
    return json(route, {});
  });
  await ctx.route(web.origin + "/api/**", (route) => json(route, {}));
  const page = await ctx.newPage();
  await page.addInitScript(() => { try { localStorage.setItem("sroka.onboarded", "1"); } catch {} });
  await page.goto(web.origin + path);
  return { page, ctx };
}

// ---------- composition ----------
const b64 = (buf) => "data:image/png;base64," + buf.toString("base64");
const GLYPH = readFileSync(join(root, "docs/brand/icon-rounded.svg"), "utf8");
const MARK = "data:image/svg+xml;base64," + Buffer.from(GLYPH).toString("base64");
const FRAME_CSS = `
@import url("https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;800&display=swap");
*{box-sizing:border-box;margin:0}
body{font-family:Outfit,system-ui,sans-serif;color:#15171c;background:#fbfaf7;overflow:hidden}
.stripe{width:56px;height:8px;border-radius:4px;background:linear-gradient(112deg,#1e6f8f,#4f9fbf 60%,#7cc0da)}
.brandrow{display:flex;align-items:center;gap:12px;font-weight:600;font-size:26px}
.brandrow img{width:40px;height:40px;border-radius:9px}
.shadow{box-shadow:0 2px 4px rgba(21,23,28,.08),0 24px 60px -12px rgba(21,23,28,.28),0 0 0 1px rgba(21,23,28,.08)}`;
const frame = (inner, w = 1280, h = 800) => `<!doctype html><meta charset="utf-8"><style>${FRAME_CSS}
body{width:${w}px;height:${h}px;position:relative;background:radial-gradient(1200px 600px at 85% -10%,#dcebf1 0,#fbfaf7 60%)}
${inner.css || ""}</style><body>${inner.html}</body>`;

async function renderHtml(html, w, h, file, { transparent = false } = {}) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  await page.setContent(html, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  await page.screenshot({ path: join(out, file), omitBackground: transparent });
  await ctx.close();
  console.log("wrote", file);
}

// Headline on the left, a real capture on the right (or below for wide captures).
const split = (head, sub, shot, { shotW, shotH, right = 90, top = 0 }) => ({
  css: `.copy{position:absolute;left:84px;top:0;bottom:0;width:480px;display:flex;flex-direction:column;justify-content:center;gap:22px}
  h1{font-size:62px;line-height:1.04;font-weight:800;letter-spacing:-.02em}
  p.sub{font-size:24px;line-height:1.4;color:#4a4c52}
  .brand{position:absolute;left:84px;top:52px}
  .shot{position:absolute;right:${right}px;top:${top || (800 - shotH) / 2}px;width:${shotW}px;height:${shotH}px;border-radius:14px;overflow:hidden;background:#fff}
  .shot img{width:100%;height:100%;display:block;object-fit:cover;object-position:top left}`,
  html: `<div class="brand brandrow"><img src="${MARK}">Sroka</div><div class="copy"><div class="stripe"></div><h1>${head}</h1><p class="sub">${sub}</p></div><div class="shot shadow"><img src="${shot}"></div>`,
});
// Headline on top, wide capture beneath.
const stack = (head, sub, shot, { shotW, shotH }) => ({
  css: `.copy{position:absolute;left:0;right:0;top:44px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:12px}
  h1{font-size:54px;font-weight:800;letter-spacing:-.02em;line-height:1.05} p.sub{font-size:23px;color:#4a4c52}
  .shot{position:absolute;left:${(1280 - shotW) / 2}px;top:196px;width:${shotW}px;height:${shotH}px;border-radius:14px 14px 0 0;overflow:hidden;background:#fff}
  .shot img{width:100%;display:block}`,
  html: `<div class="copy"><div class="stripe"></div><h1>${head}</h1><p class="sub">${sub}</p></div><div class="shot shadow"><img src="${shot}"></div>`,
});

const popupSaved = await capturePopup(false);
const popupTags = await capturePopup(true);
const optionsPng = await captureOptions();

let w = await webPage("/app/");
await w.page.waitForSelector("text=The Quiet Craft of Bookbinding");
await w.page.waitForTimeout(1200);
const libraryPng = await w.page.screenshot();
await w.ctx.close();

w = await webPage(`/app/item/${ITEMS[0].id}`, { width: 1180, height: 700 });
await w.page.waitForSelector("iframe", { timeout: 15000 });
await w.page.waitForTimeout(2500);
const readerPng = await w.page.screenshot();
await w.ctx.close();
writeFileSync(join(process.env.TMPDIR || "/tmp", "sroka-store-readerdebug.png"), readerPng);

// 1. popup saved
await renderHtml(
  frame(split("Save any page in one click", "Press the Sroka button, or Alt+Shift+S. It’s in your library, ready to read later.", b64(popupSaved), { shotW: 420, shotH: Math.round(420 * (await dims(popupSaved)).ratio), right: 120 })),
  1280, 800, "screenshot-1-save.png");
// 2. tags
await renderHtml(
  frame(split("Tag it as you save", "Add tags without leaving the page, and find it again in a second.", b64(popupTags), { shotW: 420, shotH: Math.round(420 * (await dims(popupTags)).ratio), right: 120 })),
  1280, 800, "screenshot-2-tags.png");
// 3. library
await renderHtml(frame(stack("Everything you saved, in one place", "Your library syncs to the Sroka web app and the Android app.", b64(libraryPng), { shotW: 1100, shotH: 604 })), 1280, 800, "screenshot-3-library.png");
// 4. reader
await renderHtml(frame(stack("Then read it, distraction-free", "Clean text, offline copies, and your place is remembered.", b64(readerPng), { shotW: 1100, shotH: 604 })), 1280, 800, "screenshot-4-reader.png");
// 5. options
await renderHtml(
  frame(split("You stay in control", "Use your own server, choose what is captured, and opt in or out of statistics.", b64(optionsPng), { shotW: 560, shotH: Math.round(560 * (await dims(optionsPng)).ratio), right: 100 })),
  1280, 800, "screenshot-5-settings.png");

// icon 128: 96 px art, 16 px transparent padding
await renderHtml(`<!doctype html><style>html,body{margin:0;background:transparent}img{position:absolute;left:16px;top:16px;width:96px;height:96px}</style><img src="${MARK}">`, 128, 128, "icon-128.png", { transparent: true });

// promo tiles
const tile = (w, h, big, tag, markSize) => ({
  css: `.c{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:${Math.round(markSize * 0.3)}px;padding:0 ${Math.round(w * 0.06)}px}
  .c img{width:${markSize}px;height:${markSize}px;border-radius:${Math.round(markSize * 0.22)}px;flex:none}
  .t{display:flex;flex-direction:column;gap:${Math.round(h * 0.03)}px}
  h1{font-size:${big}px;font-weight:800;letter-spacing:-.02em;line-height:1}
  p{font-size:${Math.round(big * 0.36)}px;color:#4a4c52;line-height:1.25;max-width:${Math.round(w * 0.55)}px}
  ${w < 600 ? "p{white-space:nowrap;font-size:19px;max-width:none}" : ""}
  .stripe{height:${Math.round(h * 0.02)}px;width:${Math.round(w * 0.05)}px;margin-bottom:${Math.round(h * 0.03)}px}`,
  html: `<div class="c"><img src="${MARK}"><div class="t"><div class="stripe"></div><h1>Sroka</h1><p>${tag}</p></div></div>`,
});
const TAGLINE = "Save it now. Read it later.";
const frameAt = (inner, w, h) => frame(inner, w, h);
await renderHtml(frameAt(tile(440, 280, 60, TAGLINE, 84), 440, 280), 440, 280, "promo-small-440x280.png");
await renderHtml(frameAt(tile(1400, 560, 132, "Save any article in one click. Read it on your phone, offline, anywhere.", 220), 1400, 560), 1400, 560, "marquee-1400x560.png");

async function dims(buf) {
  // PNG header: width at 16, height at 20
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20), ratio: buf.readUInt32BE(20) / buf.readUInt32BE(16) };
}

await browser.close();
ext.s.close();
web.s.close();
