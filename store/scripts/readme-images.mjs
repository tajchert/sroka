// Generates the bespoke README showcase images into docs/readme/.
//
// Real UI, cohesive sample data: serves the BUILT extension (apps/extension/.output/chrome-mv3)
// and the BUILT web app (apps/web/dist) with local API stubs (consent pre-answered so no banner
// obscures the UI), captures clean light & dark views in headless Chromium, and composes them
// alongside unaltered Android Compose & iOS SwiftUI reference screenshots.
//
// Run from the repo root after `npm run build -w @sroka/web -w @sroka/extension`:
//   PW_CORE=/path/to/node_modules/playwright-core node store/scripts/readme-images.mjs
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { homedir } from "node:os";

const root = new URL("../../", import.meta.url).pathname;
const out = join(root, "docs/readme");
mkdirSync(out, { recursive: true });

const { chromium } = createRequire(import.meta.url)(process.env.PW_CORE || "playwright-core");
const chromePath =
  process.env.CHROME ||
  join(
    homedir(),
    "Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
  );

// ---------- cohesive sample library (matches Android store references) ----------
const NOW = Date.now();
const H = 3600e3;

const PALETTES = [
  ["#1e6f8f", "#6cb3ce", "#f2c84b"],
  ["#29465b", "#7fa8c4", "#f4dfb0"],
  ["#2c6b57", "#8ec8ae", "#f5e8c7"],
  ["#8c4a32", "#e3a585", "#f7ecd5"],
  ["#364966", "#8ea7cc", "#f2c84b"],
  ["#4d3e6b", "#a998cc", "#f2c84b"],
];

const leadSvg = (i) => {
  const [a, b, c] = PALETTES[i % PALETTES.length];
  const variants = [
    `<circle cx="176" cy="48" r="24" fill="${c}" opacity=".92"/><path d="M0 160 L58 92 L114 126 L166 74 L240 138 V160Z" fill="#15171c" opacity=".32"/><path d="M0 160 L82 114 L152 140 L240 104 V160Z" fill="#15171c" opacity=".2"/>`,
    `<rect x="28" y="34" width="184" height="92" rx="12" fill="#ffffff" opacity=".16"/><circle cx="72" cy="72" r="22" fill="${c}" opacity=".9"/><path d="M28 126 L96 86 L146 112 L212 66 V126Z" fill="#15171c" opacity=".28"/>`,
    `<circle cx="66" cy="54" r="28" fill="${c}" opacity=".88"/><path d="M0 116 Q72 80 144 112 T240 96 V160 H0Z" fill="#15171c" opacity=".28"/><path d="M0 134 Q90 108 176 132 T240 120 V160 H0Z" fill="#15171c" opacity=".18"/>`,
    `<circle cx="164" cy="52" r="20" fill="${c}" opacity=".9"/><path d="M24 160 L88 64 L148 160Z" fill="#15171c" opacity=".26"/><path d="M98 160 L158 84 L224 160Z" fill="#15171c" opacity=".18"/>`,
  ];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 160" preserveAspectRatio="xMidYMid slice"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="240" height="160" fill="url(#g)"/>${variants[i % variants.length]}</svg>`;
  return "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");
};

const ARTICLES = [
  {
    title: "How a magpie decides what to collect",
    site: "Nature Notes",
    host: "nature.example.org",
    author: "Edda Marlowe",
    min: 9,
    tags: ["birds", "nature"],
    fav: true,
    progress: 0.34,
    excerpt: "Magpies are famous for collecting bright objects, yet field studies reveal a sharper instinct for curiosity and memory.",
  },
  {
    title: "The slow web: why reading later still matters",
    site: "Longreads",
    host: "longreads.example.com",
    author: "Tobias Wren",
    min: 14,
    tags: ["longreads", "web"],
    fav: false,
    progress: 0.72,
    excerpt: "Reading later only works when your list stays calm enough to trust — a quiet shelf you can return to anywhere.",
  },
  {
    title: "The quiet intelligence of crows and magpies",
    site: "Nature Notes",
    host: "nature.example.org",
    author: "Rune Calloway",
    min: 8,
    tags: ["birds", "nature"],
    fav: true,
    progress: 0,
    excerpt: "Corvids remember individual faces, plan ahead for tomorrow’s meal, and solve multi-step puzzles without trial and error.",
  },
  {
    title: "A field guide to quiet mornings",
    site: "Slow Living",
    host: "slowliving.example.net",
    author: "Pia Anselm",
    min: 6,
    tags: ["nature", "essays"],
    fav: false,
    progress: 0,
    excerpt: "Before the inbox opens and the notifications start, thirty uninterrupted minutes with saved essays change the pace of a day.",
  },
  {
    title: "Ask HN: What tools do you use to read long articles offline?",
    site: "Hacker News",
    host: "news.ycombinator.com",
    author: "maren_k",
    min: 11,
    tags: ["tech", "longreads"],
    fav: false,
    progress: 0,
    excerpt: "Ever since Pocket shut down, I’ve wanted a fast offline reader that saves clean text, images, and HN threads.",
  },
  {
    title: "Notes on tagging a growing library",
    site: "Craft & Tools",
    host: "blog.example.dev",
    author: "Ines Okafor",
    min: 5,
    tags: ["tech", "design"],
    fav: true,
    progress: 0,
    excerpt: "A small, deliberate set of tags beats a thousand unread bookmarks — especially when full-text search handles the rest.",
  },
  {
    title: "Field Notes on Small Tools (2026).pdf",
    site: "PDF",
    host: "sroka.app",
    author: null,
    min: 12,
    tags: ["design"],
    fav: false,
    progress: 0,
    kind: "pdf",
    fileName: "Field Notes on Small Tools (2026).pdf",
    fileSize: 2_480_000,
    excerpt: "Compact essays on durable software, local-first storage, and calm interfaces.",
  },
];

const uid = (n) => `0198a000-0000-7000-8000-${String(n).padStart(12, "0")}`;
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");

const ITEMS = ARTICLES.map((a, i) => {
  const url = `https://${a.host}/${slug(a.title)}`;
  return {
    id: uid(i + 1),
    url,
    canonicalUrl: url,
    title: a.title,
    excerpt: a.excerpt,
    siteName: a.site,
    author: a.author,
    lang: "en",
    leadImageUrl: a.kind === "pdf" ? null : leadSvg(i),
    leadImageKey: a.kind === "pdf" ? null : "thumb.webp",
    wordCount: a.min * 230,
    readingMinutes: a.min,
    contentId: uid(100 + i),
    contentPrivate: false,
    parseStatus: "ok",
    parseError: null,
    status: "unread",
    isFavorite: a.fav,
    progress: a.progress,
    progressAnchor: null,
    savedAt: NOW - (i * 4 + 1) * H,
    archivedAt: null,
    lastReadAt: a.progress > 0 ? NOW - H : null,
    source: "extension",
    tags: a.tags,
    kind: a.kind ?? "article",
    fileName: a.fileName ?? null,
    fileSize: a.fileSize ?? null,
    seq: i + 1,
  };
});

const TAG_NAMES = ["birds", "design", "essays", "longreads", "nature", "tech", "web"];
const TAGS = TAG_NAMES.map((name, i) => ({
  id: uid(200 + i),
  name,
  count: ITEMS.filter((it) => it.tags.includes(name)).length + (i % 3) * 2,
  seq: i + 1,
}));

const heroArticleHtml = () => {
  const it = ITEMS[2]; // The quiet intelligence of crows and magpies
  const art = leadSvg(0);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${it.title}</title></head><body><article>
<h1>${it.title}</h1>
<p class="byline">${it.author} · ${it.siteName} · 8 min read</p>
<figure><img src="${art}" alt="Geometric mountain sunrise illustration" style="border-radius:10px;width:100%;aspect-ratio:16/7;object-fit:cover"><figcaption>Corvids build mental maps of both terrain and social relationships.</figcaption></figure>
<p>Watch a Eurasian magpie hop across a quiet courtyard at dawn and you start noticing how little of its movement is accidental. Every pause, head tilt, and cached morsel is part of an unusually nimble memory system.</p>
<p>In controlled studies across Europe, magpies became the first non-mammals to pass the mirror self-recognition test — removing a bright mark placed beneath their beaks after catching sight of themselves.</p>
<h2>Why curiosity beats habit</h2>
<p>Most long reads worth keeping work the same way: you spot them in the middle of a busy afternoon, stash them in a single tap, and return when the train pulls out of the station and the signal drops away.</p>
</article></body></html>`;
};

const hnDiscussionHtml = () => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Ask HN: What tools do you use to read long articles offline?</title></head><body><article>
<h1>Ask HN: What tools do you use to read long articles offline?</h1>
<p class="byline">maren_k · Hacker News</p>
<div class="sr-thread">
  <div class="sr-post">
    <p class="sr-post-head"><span class="sr-post-who"><a href="https://news.ycombinator.com/user?id=maren_k">maren_k</a></span><span class="sr-post-date"> · Nov 18, 2026</span></p>
    <div class="sr-post-body"><p>Ever since Pocket shut down, I’ve wanted a fast offline reader that saves clean text, images, and HN threads for flights and train commutes — ideally open source so it won’t disappear on me again.</p></div>
    <p class="sr-post-stats"><small>284 points · 142 comments</small></p>
  </div>
</div>
<h2>Comments</h2>
<div class="sr-comments">
  <div class="sr-post">
    <p class="sr-post-head"><span class="sr-post-who"><strong><a href="https://news.ycombinator.com/user?id=tomasz_r">tomasz_r</a></strong></span><span class="sr-post-date"> · Nov 18, 2026</span></p>
    <div class="sr-post-body"><p>The biggest dealbreaker for me was losing comment threads. Half the time the Hacker News or Reddit discussion is better than the linked essay, and I want to read both on the plane.</p></div>
    <div class="sr-replies">
      <div class="sr-reply sr-post-focus">
        <p class="sr-post-head"><span class="sr-post-who"><strong><a href="https://news.ycombinator.com/user?id=claire_v">claire_v</a></strong></span><span class="sr-post-date"> · Nov 18, 2026</span></p>
        <div class="sr-post-body"><p>Same here — keeping nested replies intact offline plus full-text search across downloaded articles is what finally let me close 60 browser tabs.</p></div>
        <div class="sr-replies">
          <div class="sr-reply">
            <p class="sr-post-head"><span class="sr-post-who"><strong><a href="https://news.ycombinator.com/user?id=maren_k">maren_k</a></strong> <small>OP</small></span><span class="sr-post-date"> · Nov 18, 2026</span></p>
            <div class="sr-post-body"><p>And being able to self-host on Cloudflare Workers with Durable Objects means zero server babysitting while still owning my whole archive.</p></div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
</article></body></html>`;

// ---------- local static servers ----------
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".json": "application/json",
  ".webmanifest": "application/json",
};

const serve = (dir, { spa = false, extra } = {}) =>
  new Promise((resolve) => {
    const s = createServer((req, res) => {
      const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (extra) {
        const r = extra(p);
        if (r) {
          res.writeHead(200, { "content-type": "text/html; charset=utf-8", "access-control-allow-origin": "*" });
          return res.end(r);
        }
      }
      let f = normalize(join(dir, p));
      if (!f.startsWith(dir)) {
        res.writeHead(403);
        return res.end();
      }
      if (existsSync(f) && statSync(f).isDirectory()) f = join(f, "index.html");
      if (!existsSync(f) && spa) f = join(dir, "app/index.html");
      if (!existsSync(f)) {
        res.writeHead(404);
        return res.end();
      }
      res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
      res.end(readFileSync(f));
    }).listen(0, "127.0.0.1", () => resolve({ s, origin: `http://127.0.0.1:${s.address().port}` }));
  });

const ext = await serve(join(root, "apps/extension/.output/chrome-mv3"));
const web = await serve(join(root, "apps/web/dist"), {
  spa: true,
  extra: (p) => {
    if (p === "/__c/2/article.html") return heroArticleHtml();
    if (p === "/__c/4/article.html") return hnDiscussionHtml();
    return null;
  },
});

const browser = await chromium.launch({ executablePath: chromePath, headless: true });
const json = (route, body, status = 200) =>
  route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

// ---------- 1. Capture clean Extension popup (consent pre-answered) ----------
const CHROME_STUB = (state) => `(() => {
  const S = ${JSON.stringify(state)};
  const mk = (data) => ({
    get: async (k) => { if (k == null) return { ...data }; const ks = typeof k === "string" ? [k] : Array.isArray(k) ? k : Object.keys(k); const r = {}; for (const x of ks) if (x in data) r[x] = data[x]; return r; },
    set: async (o) => { Object.assign(data, o); },
    remove: async (k) => { for (const x of [].concat(k)) delete data[x]; },
  });
  window.close = () => {};
  window.chrome = {
    storage: { local: mk({ ...S.local }), session: mk({}) },
    tabs: { query: async () => [S.tab], create: async () => {} },
    runtime: {
      sendMessage: async (m) => (m.type === "save-tab" ? { ok: true, created: true, item: S.item } : { ok: true }),
      getManifest: () => ({ version: "0.7.0" }),
      id: "stub",
    },
    commands: { getAll: async () => [{ name: "_execute_action", shortcut: "Alt+Shift+S" }] },
    permissions: { contains: async () => true, request: async () => true },
    alarms: { create() {}, clear: async () => true, onAlarm: { addListener() {} } },
  };
})();`;

const savedItem = ITEMS[2]; // "The quiet intelligence of crows and magpies"

async function captureExtensionPopup() {
  const ctx = await browser.newContext({ viewport: { width: 420, height: 640 }, deviceScaleFactor: 2 });
  await ctx.route("https://api.sroka.app/**", (route) => {
    const u = new URL(route.request().url());
    if (u.pathname === "/v1/tags") return json(route, { tags: TAGS });
    if (u.pathname === "/v1/tags/suggestions")
      return json(route, { recent: ["birds", "nature", "longreads"], frequent: ["tech", "design"], current: ["birds", "nature"] });
    if (u.pathname.startsWith("/v1/items/")) return json(route, { item: savedItem });
    return json(route, {});
  });
  await ctx.route("https://fonts.googleapis.com/**", (r) => r.continue());
  await ctx.addInitScript(
    CHROME_STUB({
      local: {
        token: "demo",
        email: "reader@example.com",
        signedOut: false,
        serverUrl: "https://api.sroka.app",
        captureHtml: true,
        "sroka.hasSaved.v1": true,
        "sroka.consent.v1": { analytics: false, errors: false },
      },
      tab: { id: 1, url: savedItem.url, title: savedItem.title },
      item: savedItem,
    }),
  );
  const page = await ctx.newPage();
  await page.goto(ext.origin + "/popup.html");
  await page.waitForSelector(".item-title");
  await page.waitForTimeout(700);
  const png = await page.locator(".popup-card").screenshot();
  await ctx.close();
  return png;
}

// ---------- 2. Capture clean Web App views (light & dark, zero consent banner) ----------
async function captureWeb(
  path,
  { width = 1120, height = 720, colorScheme = "light", waitFor = "text=How a magpie", reader = false, scale = 2, iframeScrollY = 0 } = {},
) {
  // Note: sandboxed srcdoc iframes in headless Chromium can clip at deviceScaleFactor > 1,
  // so reader views capture at scale 1 with an enlarged logical viewport for crisp pixels.
  const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: reader ? 1 : scale, colorScheme });
  await ctx.route("https://fonts.googleapis.com/**", (r) => r.continue());
  await ctx.route(web.origin + "/v1/**", (route) => {
    const u = new URL(route.request().url());
    const m = u.pathname.match(/^\/v1\/items\/([^/]+)(\/content)?$/);
    if (u.pathname === "/v1/me")
      return json(route, {
        user: { id: "u1", email: "reader@example.com", name: null, emailVerified: true, createdAt: NOW - 90 * 24 * H },
        stats: { unread: ITEMS.length, archived: 18, favorites: 3, tags: TAGS.length },
        clients: { extension: true, android: true, ios: true },
      });
    if (u.pathname === "/v1/config")
      return json(route, {
        appOrigin: web.origin,
        minVersions: { android: null, ios: null, extension: null },
        features: {},
        limits: { maxOpsPerPush: 100, maxHtmlBytes: 5e6, maxImportBytes: 5e7 },
      });
    if (u.pathname === "/v1/tags") return json(route, { tags: TAGS });
    if (u.pathname === "/v1/items") return json(route, { items: ITEMS, nextCursor: null });
    if (m && m[2]) {
      const n = ITEMS.findIndex((x) => x.id === m[1]);
      return json(route, {
        articleUrl: `${web.origin}/__c/${n}/article.html`,
        baseUrl: `${web.origin}/__c/${n}/`,
        packageUrl: `${web.origin}/__c/${n}/p.zip`,
        documentUrl: null,
        expiresAt: NOW + 24 * H,
      });
    }
    if (m) return json(route, { item: ITEMS.find((x) => x.id === m[1]) });
    return json(route, {});
  });
  await ctx.route(web.origin + "/api/**", (route) => json(route, {}));

  const page = await ctx.newPage();
  await page.addInitScript(() => {
    try {
      localStorage.setItem("sroka.onboarded", "1");
      localStorage.setItem("sroka.consent.v1", JSON.stringify({ analytics: false, errors: false }));
    } catch {}
  });
  await page.goto(web.origin + path);
  if (reader) {
    await page.waitForSelector("iframe", { timeout: 15000 });
    await page.waitForTimeout(1600);
    if (iframeScrollY > 0) {
      await page.frameLocator("iframe").locator("body").evaluate((_, y) => window.scrollTo(0, y), iframeScrollY);
      await page.waitForTimeout(300);
    }
  } else {
    await page.waitForSelector(waitFor, { timeout: 15000 });
    await page.waitForTimeout(900);
  }
  const png = await page.screenshot();
  await ctx.close();
  return png;
}

const b64 = (buf) => "data:image/png;base64," + buf.toString("base64");
const loadPng = (rel) => b64(readFileSync(join(root, rel)));

console.log("Capturing live Extension & Web UI…");
const popupSaved = b64(await captureExtensionPopup());
const webLibLight = b64(await captureWeb("/app/", { width: 1020, height: 680, colorScheme: "light" }));
const webLibDark = b64(await captureWeb("/app/", { width: 1020, height: 680, colorScheme: "dark" }));
const webArticleReader = b64(await captureWeb(`/app/item/${ITEMS[2].id}`, { width: 1060, height: 820, colorScheme: "light", reader: true }));
const webHnReader = b64(await captureWeb(`/app/item/${ITEMS[4].id}`, { width: 1060, height: 820, colorScheme: "light", reader: true, iframeScrollY: 270 }));

// Raw unaltered native reference screenshots
const androidLibLight = loadPng(
  "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneLibraryLight_StorePhoneLibraryLight_5f8a96f7_0.png",
);
const androidLibDark = loadPng(
  "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneLibraryDark_StorePhoneLibraryDark_b7c394c7_0.png",
);
const androidSaved = loadPng(
  "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneSaved_StorePhoneSaved_f8d098c3_0.png",
);
const androidSearch = loadPng(
  "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneSearch_StorePhoneSearch_174a678f_0.png",
);
const androidFoldedLight = loadPng(
  "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StoreFoldedLibraryLight_StoreFoldedLibraryLight_12cb215b_0.png",
);
const androidUnfoldedTags = loadPng(
  "apps/android/app/src/screenshotTestPlayDebug/reference/app/sroka/StoreScreenshotTestsKt/StoreFoldUnfoldedTags_StoreFoldUnfoldedTags_15e5e385_0.png",
);

const iosReaderLight = loadPng("apps/ios/docs/shots/l2/phone-reader.png");
const iosReaderSepia = loadPng("apps/ios/docs/shots/l2/phone-reader-sepia.png");
const iosReaderDark = loadPng("apps/ios/docs/shots/l2/phone-reader-dark.png");
const iosWikiLight = loadPng("apps/ios/docs/shots/journeys/b3-reader-top.png");
const iosAppearance = loadPng("apps/ios/Modules/Tests/SnapshotTests/__Snapshots__/ReaderSnapshotTests/appearanceSheetLight.1.png");

// ---------- shared composite styling ----------
const BASE_CSS = `
@import url("https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&display=swap");
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Outfit,-apple-system,BlinkMacSystemFont,system-ui,sans-serif;overflow:hidden;-webkit-font-smoothing:antialiased}
.mat-light{
  background:
    radial-gradient(900px 520px at 88% -8%, rgba(30,111,143,0.14) 0%, transparent 62%),
    radial-gradient(700px 480px at 8% 108%, rgba(242,200,75,0.12) 0%, transparent 58%),
    linear-gradient(155deg, #edf4f7 0%, #f5f3ed 56%, #eaf1f4 100%);
  color:#15171c;
}
.mat-dark{
  background:
    radial-gradient(920px 540px at 86% -6%, rgba(79,159,191,0.20) 0%, transparent 60%),
    radial-gradient(700px 460px at 10% 108%, rgba(242,200,75,0.09) 0%, transparent 56%),
    linear-gradient(155deg, #101b22 0%, #14191f 58%, #0e181e 100%);
  color:#f1efe9;
}
.browser{
  border-radius:16px;
  overflow:hidden;
  background:#fbfaf7;
  box-shadow:0 2px 6px rgba(15,23,32,.08), 0 28px 64px -16px rgba(15,23,32,.26), 0 0 0 1px rgba(21,23,28,.10);
}
.browser.dark{
  background:#15171c;
  box-shadow:0 2px 6px rgba(0,0,0,.35), 0 32px 72px -14px rgba(0,0,0,.62), 0 0 0 1px rgba(255,255,255,.11);
}
.bbar{
  height:36px;
  display:flex;
  align-items:center;
  padding:0 14px;
  gap:7px;
  background:#f2f0ea;
  border-bottom:1px solid rgba(21,23,28,.08);
}
.browser.dark .bbar{
  background:#1e2229;
  border-bottom:1px solid rgba(255,255,255,.08);
}
.dot{width:10px;height:10px;border-radius:50%;background:#d6d3cb}
.browser.dark .dot{background:#373d47}
.burl{
  margin-left:10px;
  font-size:12px;
  font-weight:500;
  color:#6b6d73;
  background:rgba(21,23,28,.05);
  padding:3px 12px;
  border-radius:999px;
  letter-spacing:.01em;
}
.browser.dark .burl{
  color:#9ca1aa;
  background:rgba(255,255,255,.06);
}
.device{
  border-radius:30px;
  padding:8px;
  background:#181b20;
  box-shadow:0 4px 10px rgba(15,23,32,.14), 0 28px 60px -12px rgba(15,23,32,.34), 0 0 0 1px rgba(255,255,255,.14) inset;
}
.device-inner{
  width:100%;
  height:100%;
  border-radius:23px;
  overflow:hidden;
  background:#fbfaf7;
}
.device-inner.dark{background:#15171c}
.device-inner img{width:100%;height:100%;display:block;object-fit:cover;object-position:top center}
.pill{
  display:inline-flex;
  align-items:center;
  gap:8px;
  padding:6px 14px;
  border-radius:999px;
  font-size:14px;
  font-weight:600;
  letter-spacing:.005em;
  background:rgba(255,255,255,.82);
  color:#15171c;
  border:1px solid rgba(21,23,28,.09);
  box-shadow:0 2px 8px rgba(15,23,32,.06);
}
.mat-dark .pill{
  background:rgba(255,255,255,.08);
  color:#edf2f5;
  border:1px solid rgba(255,255,255,.12);
}
.pill .num{
  display:inline-flex;
  align-items:center;
  justify-content:center;
  width:21px;
  height:21px;
  border-radius:999px;
  background:#1e6f8f;
  color:#fff;
  font-size:12px;
  font-weight:700;
}
.pill .accent-dot{
  width:8px;
  height:8px;
  border-radius:999px;
  background:#1e6f8f;
}
.mat-dark .pill .accent-dot{background:#5fb4d4}
.pill .beak-dot{
  width:8px;
  height:8px;
  border-radius:999px;
  background:#f2c84b;
}
`;

async function renderShot(file, w, h, html) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  await page.setContent(`<!doctype html><meta charset="utf-8"><style>${BASE_CSS}</style>${html}`, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(250);
  await page.screenshot({ path: join(out, file) });
  await ctx.close();
  console.log("wrote docs/readme/" + file);
}

// ---------- SHOT 1: Hero (light + dark GitHub variants) ----------
function heroHtml(mode) {
  const dark = mode === "dark";
  const webImg = dark ? webLibDark : webLibLight;
  const androidImg = dark ? androidLibDark : androidLibLight;
  const iosImg = dark ? iosReaderDark : iosReaderLight;
  return `<body class="${dark ? "mat-dark" : "mat-light"}" style="width:1600px;height:860px;position:relative">
    <style>
      .web-wrap{position:absolute;left:44px;top:44px;width:930px;height:690px}
      .web-wrap .bcontent{height:654px;overflow:hidden}
      .web-wrap .bcontent img{width:100%;height:100%;object-fit:cover;object-position:top left;display:block}
      .android-wrap{position:absolute;right:330px;top:148px;width:338px;height:600px;z-index:2}
      .ios-wrap{position:absolute;right:44px;top:72px;width:316px;height:686px;z-index:3}
      .footer-bar{position:absolute;left:44px;right:44px;bottom:26px;display:flex;align-items:center;justify-content:space-between}
      .chips{display:flex;gap:10px}
      .subtle{font-size:14px;font-weight:500;opacity:.72}
    </style>
    <div class="browser ${dark ? "dark" : ""} web-wrap">
      <div class="bbar">
        <span class="dot"></span><span class="dot"></span><span class="dot"></span>
        <span class="burl">sroka.app/app</span>
      </div>
      <div class="bcontent"><img src="${webImg}"></div>
    </div>
    <div class="device android-wrap">
      <div class="device-inner ${dark ? "dark" : ""}"><img src="${androidImg}" style="object-fit:contain;background:${dark ? "#15171c" : "#fbfaf7"}"></div>
    </div>
    <div class="device ios-wrap">
      <div class="device-inner ${dark ? "dark" : ""}"><img src="${iosImg}"></div>
    </div>
    <div class="footer-bar">
      <div class="chips">
        <span class="pill"><span class="accent-dot"></span>Web &amp; PWA</span>
        <span class="pill"><span class="accent-dot"></span>Android (Compose)</span>
        <span class="pill"><span class="beak-dot"></span>iPhone &amp; iPad (SwiftUI)</span>
      </div>
      <span class="subtle">One synced library · automatically downloaded for offline reading</span>
    </div>
  </body>`;
}

await renderShot("hero-light.png", 1600, 860, heroHtml("light"));
await renderShot("hero-dark.png", 1600, 860, heroHtml("dark"));

// ---------- SHOT 2: Save anywhere → Read offline ----------
await renderShot(
  "save-offline.png",
  1440,
  840,
  `<body class="mat-light" style="width:1440px;height:840px;position:relative">
    <style>
      .col-left{position:absolute;left:44px;top:38px;width:448px;bottom:38px;display:flex;flex-direction:column;gap:20px;align-items:flex-start}
      .col-right{position:absolute;right:44px;top:38px;width:856px;bottom:38px;display:flex;flex-direction:column;gap:18px;align-items:flex-start}
      .card{
        border-radius:16px;
        overflow:hidden;
        background:#ffffff;
        box-shadow:0 2px 6px rgba(15,23,32,.07), 0 20px 44px -12px rgba(15,23,32,.20), 0 0 0 1px rgba(21,23,28,.09);
      }
      .ext-card{padding:0;width:434px}
      .ext-card img{width:100%;display:block}
      .ext-bar{
        height:30px;background:#f2f0ea;border-bottom:1px solid rgba(21,23,28,.08);
        display:flex;align-items:center;justify-content:space-between;padding:0 12px;font-size:12px;font-weight:600;color:#4a4c52;
      }
      .android-saved{
        width:434px;height:316px;position:relative;overflow:hidden;border-radius:20px;background:#fbfaf7;
        box-shadow:0 2px 6px rgba(15,23,32,.08), 0 22px 48px -12px rgba(15,23,32,.22), 0 0 0 1px rgba(21,23,28,.10);
      }
      .android-saved img{
        position:absolute;left:0;bottom:0;width:100%;height:auto;display:block;
      }
      .tag-label{
        position:absolute;top:12px;right:12px;z-index:2;
        background:rgba(21,23,28,.78);color:#fff;font-size:11.5px;font-weight:600;padding:4px 10px;border-radius:999px;
      }
      .arrow-bridge{
        position:absolute;left:492px;top:418px;width:52px;height:52px;border-radius:999px;
        background:#1e6f8f;color:#fff;display:flex;align-items:center;justify-content:center;
        box-shadow:0 8px 24px rgba(30,111,143,.32), 0 0 0 4px rgba(255,255,255,.75);
        z-index:4;
      }
      .reader-win{flex:1;width:100%;display:flex;flex-direction:column}
      .reader-body{flex:1;overflow:hidden;position:relative}
      .reader-body img{width:100%;height:100%;object-fit:cover;object-position:top left;display:block}
      .offline-chip{
        position:absolute;right:12px;top:5px;
        display:inline-flex;align-items:center;gap:6px;
        background:#dcebf1;color:#15536b;border:1px solid rgba(30,111,143,.22);
        font-size:12px;font-weight:600;padding:4px 10px;border-radius:999px;
      }
    </style>
    <div class="col-left">
      <span class="pill"><span class="num">1</span>Save from Chrome or mobile share sheet</span>
      <div class="card ext-card">
        <div class="ext-bar"><span>Chrome extension</span><span style="opacity:.6">Alt+Shift+S</span></div>
        <img src="${popupSaved}">
      </div>
      <div class="android-saved">
        <span class="tag-label">Android · Share → Sroka</span>
        <img src="${androidSaved}">
      </div>
    </div>

    <div class="arrow-bridge" aria-hidden="true">
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14"/><path d="m13 6 6 6-6 6"/></svg>
    </div>

    <div class="col-right">
      <span class="pill"><span class="num">2</span>Clean reader — text &amp; images saved offline</span>
      <div class="browser reader-win">
        <div class="bbar" style="position:relative">
          <span class="dot"></span><span class="dot"></span><span class="dot"></span>
          <span class="burl">sroka.app/app/item/crows-and-magpies</span>
          <span class="offline-chip">✈ Ready offline</span>
        </div>
        <div class="reader-body"><img src="${webArticleReader}"></div>
      </div>
    </div>
  </body>`,
);

// ---------- SHOT 3: Organize, offline full-text search & saved discussions ----------
await renderShot(
  "organize-and-threads.png",
  1440,
  800,
  `<body class="mat-light" style="width:1440px;height:800px;position:relative">
    <style>
      .left-panel{position:absolute;left:44px;top:38px;width:426px;bottom:38px;display:flex;flex-direction:column;gap:18px;align-items:flex-start}
      .right-panel{position:absolute;right:44px;top:38px;width:892px;bottom:38px;display:flex;flex-direction:column;gap:18px;align-items:flex-start}
      .search-phone{width:386px;height:666px}
      .hn-browser{flex:1;width:100%;display:flex;flex-direction:column}
      .hn-body{flex:1;overflow:hidden}
      .hn-body img{width:100%;height:100%;object-fit:cover;object-position:top left;display:block}
    </style>
    <div class="left-panel">
      <span class="pill"><span class="accent-dot"></span>Offline full-text search &amp; tags</span>
      <div class="device search-phone">
        <div class="device-inner"><img src="${androidSearch}" style="object-fit:cover;object-position:top center"></div>
      </div>
    </div>
    <div class="right-panel">
      <span class="pill"><span class="beak-dot"></span>Hacker News, Reddit &amp; X threads — replies intact</span>
      <div class="browser hn-browser">
        <div class="bbar">
          <span class="dot"></span><span class="dot"></span><span class="dot"></span>
          <span class="burl">news.ycombinator.com · saved discussion</span>
        </div>
        <div class="hn-body"><img src="${webHnReader}"></div>
      </div>
    </div>
  </body>`,
);

// ---------- SHOT 4: Native UX for foldables, tablets & phones ----------
await renderShot(
  "adaptive-foldable-tablet.png",
  1600,
  900,
  `<body class="mat-light" style="width:1600px;height:900px;position:relative">
    <style>
      .top-pills{position:absolute;left:46px;right:46px;top:32px;display:flex;justify-content:space-between;align-items:center}
      .unfolded{
        position:absolute;left:186px;top:96px;width:888px;height:666px;
        border-radius:30px;padding:10px;background:#181b20;
        box-shadow:0 6px 14px rgba(15,23,32,.14), 0 32px 68px -14px rgba(15,23,32,.34), 0 0 0 1px rgba(255,255,255,.14) inset;
      }
      .unfolded-inner{width:100%;height:100%;border-radius:21px;overflow:hidden;background:#fbfaf7}
      .unfolded-inner img{width:100%;height:100%;object-fit:cover;display:block}
      .folded{
        position:absolute;left:42px;bottom:42px;width:248px;height:400px;z-index:3;
        border-radius:26px;padding:7px;background:#181b20;
        box-shadow:0 8px 20px rgba(15,23,32,.22), 0 28px 56px -10px rgba(15,23,32,.40), 0 0 0 1px rgba(255,255,255,.16) inset;
      }
      .folded-inner{width:100%;height:100%;border-radius:19px;overflow:hidden;background:#fbfaf7}
      .folded-inner img{width:100%;height:100%;object-fit:cover;object-position:top center;display:block}
      .ios-col{
        position:absolute;right:44px;top:96px;width:452px;height:760px;
      }
      .ios-phone{
        position:absolute;right:0;top:0;width:328px;height:706px;
      }
      .ios-sheet{
        position:absolute;left:0;bottom:34px;width:246px;border-radius:20px;overflow:hidden;background:#fff;z-index:4;
        box-shadow:0 4px 12px rgba(15,23,32,.14), 0 24px 52px -10px rgba(15,23,32,.34), 0 0 0 1px rgba(21,23,28,.10);
      }
      .ios-sheet img{width:100%;display:block}
      .sub-caption{
        position:absolute;left:322px;bottom:44px;font-size:14px;font-weight:500;color:#4a4c52;
      }
    </style>
    <div class="top-pills">
      <span class="pill"><span class="accent-dot"></span>Android Foldable — cover screen &amp; dual-pane unfolded</span>
      <span class="pill"><span class="beak-dot"></span>iOS &amp; iPadOS — SwiftUI reader &amp; typography</span>
    </div>

    <div class="unfolded">
      <div class="unfolded-inner"><img src="${androidUnfoldedTags}"></div>
    </div>

    <div class="folded">
      <div class="folded-inner"><img src="${androidFoldedLight}"></div>
    </div>

    <div class="ios-col">
      <div class="device ios-phone">
        <div class="device-inner"><img src="${iosWikiLight}"></div>
      </div>
      <div class="ios-sheet"><img src="${iosAppearance}"></div>
    </div>

    <div class="sub-caption">Adaptive Kotlin &amp; Jetpack Compose layout with navigation rail and split panes</div>
  </body>`,
);

// ---------- SHOT 5: Calm reader themes (Light · Sepia · Dark) ----------
await renderShot(
  "reader-themes.png",
  1440,
  700,
  `<body class="mat-light" style="width:1440px;height:700px;position:relative">
    <style>
      .grid{
        position:absolute;inset:36px 46px 32px 46px;
        display:grid;grid-template-columns:repeat(3, 1fr);gap:36px;align-items:stretch;
      }
      .slot{display:flex;flex-direction:column;align-items:center;gap:14px}
      .frame{
        width:100%;flex:1;border-radius:26px;padding:7px;background:#181b20;
        box-shadow:0 4px 12px rgba(15,23,32,.14), 0 24px 52px -12px rgba(15,23,32,.30), 0 0 0 1px rgba(255,255,255,.14) inset;
      }
      .screen{width:100%;height:100%;border-radius:19px;overflow:hidden;position:relative}
      .screen img{width:100%;height:auto;display:block;position:absolute;left:0}
      .label{font-size:15px;font-weight:600;color:#2c3038;letter-spacing:.01em}
    </style>
    <div class="grid">
      <div class="slot">
        <div class="frame"><div class="screen" style="background:#fbfbf9"><img src="${iosReaderLight}" style="top:-122px"></div></div>
        <div class="label">Light</div>
      </div>
      <div class="slot">
        <div class="frame"><div class="screen" style="background:#f3ead8"><img src="${iosReaderSepia}" style="top:-396px"></div></div>
        <div class="label">Sepia</div>
      </div>
      <div class="slot">
        <div class="frame"><div class="screen" style="background:#121314"><img src="${iosReaderDark}" style="top:-122px"></div></div>
        <div class="label">Dark</div>
      </div>
    </div>
  </body>`,
);

await browser.close();
ext.s.close();
web.s.close();
console.log("All README images generated.");
