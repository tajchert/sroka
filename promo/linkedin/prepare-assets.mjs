#!/usr/bin/env node
// Populates promo/linkedin/assets/ with clean Sroka UI captures and native screenshots.
//
// Reuses the clean capture pattern from store/scripts/readme-images.mjs:
//   - Built extension (apps/extension/.output/chrome-mv3)
//   - Built web app (apps/web/dist)
//   - Pre-answered consent (`sroka.consent.v1 = {"analytics":false,"errors":false}`) so no banner appears
//   - Unaltered native Android Compose & iOS SwiftUI reference screenshots + rounded brand icon
//
// Usage:
//   PW_CORE=/tmp/sroka-linkedin-pw/node_modules/playwright-core node promo/linkedin/prepare-assets.mjs
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { extname, join, normalize, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const outDir = join(root, "promo/linkedin/assets");
mkdirSync(outDir, { recursive: true });

const require = createRequire(import.meta.url);
function loadPlaywright() {
  const candidates = [
    process.env.PW_CORE,
    "playwright-core",
    "/tmp/sroka-linkedin-pw/node_modules/playwright-core",
  ].filter(Boolean);
  for (const id of candidates) {
    try {
      return require(id);
    } catch {
      // try next candidate
    }
  }
  throw new Error(
    "Could not load playwright-core. Set PW_CORE=/path/to/playwright-core or install it in /tmp/sroka-linkedin-pw.",
  );
}

const { chromium } = loadPlaywright();

const defaultChromePath = join(
  homedir(),
  "Library/Caches/ms-playwright/chromium-1255/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
);
const chromePath = process.env.CHROME || (existsSync(defaultChromePath) ? defaultChromePath : undefined);

const extDistDir = join(root, "apps/extension/.output/chrome-mv3");
const webDistDir = join(root, "apps/web/dist");
if (!existsSync(extDistDir)) {
  throw new Error(`Missing built extension at ${extDistDir}. Run: npm run build -w @sroka/extension`);
}
if (!existsSync(webDistDir)) {
  throw new Error(`Missing built web app at ${webDistDir}. Run: npm run build -w @sroka/web`);
}

// ---------- 1. Copy brand mark and unaltered native reference screenshots ----------
const STATIC_COPIES = [
  ["icon.svg", "docs/brand/icon-rounded.svg"],
  [
    "android-library.png",
    "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneLibraryLight_StorePhoneLibraryLight_5f8a96f7_0.png",
  ],
  [
    "android-saved.png",
    "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneSaved_StorePhoneSaved_f8d098c3_0.png",
  ],
  [
    "android-search.png",
    "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StorePhoneSearch_StorePhoneSearch_174a678f_0.png",
  ],
  [
    "android-folded.png",
    "apps/android/feature/library/impl/src/screenshotTestDebug/reference/app/sroka/feature/library/impl/StoreScreenshotTestsKt/StoreFoldedLibraryLight_StoreFoldedLibraryLight_12cb215b_0.png",
  ],
  [
    "android-unfolded.png",
    "apps/android/app/src/screenshotTestPlayDebug/reference/app/sroka/StoreScreenshotTestsKt/StoreFoldUnfoldedTags_StoreFoldUnfoldedTags_15e5e385_0.png",
  ],
  ["ios-reader-light.png", "apps/ios/docs/shots/l2/phone-reader.png"],
  ["ios-reader-sepia.png", "apps/ios/docs/shots/l2/phone-reader-sepia.png"],
  ["ios-reader-dark.png", "apps/ios/docs/shots/l2/phone-reader-dark.png"],
  ["ios-wiki-light.png", "apps/ios/docs/shots/journeys/b3-reader-top.png"],
];

for (const [destName, relSrc] of STATIC_COPIES) {
  const src = join(root, relSrc);
  if (!existsSync(src)) {
    throw new Error(`Missing source asset: ${src}`);
  }
  const dest = join(outDir, destName);
  copyFileSync(src, dest);
  console.log(`copied  promo/linkedin/assets/${destName} (${statSync(dest).size} bytes)`);
}

// ---------- 2. Cohesive sample library (matches Android store references) ----------
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
    excerpt:
      "Magpies are famous for collecting bright objects, yet field studies reveal a sharper instinct for curiosity and memory.",
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
    excerpt:
      "Reading later only works when your list stays calm enough to trust — a quiet shelf you can return to anywhere.",
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
    excerpt:
      "Corvids remember individual faces, plan ahead for tomorrow’s meal, and solve multi-step puzzles without trial and error.",
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
    excerpt:
      "Before the inbox opens and the notifications start, thirty uninterrupted minutes with saved essays change the pace of a day.",
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
    excerpt:
      "Ever since Pocket shut down, I’ve wanted a fast offline reader that saves clean text, images, and HN threads.",
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
    excerpt:
      "A small, deliberate set of tags beats a thousand unread bookmarks — especially when full-text search handles the rest.",
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
  const it = ITEMS[2]; // "The quiet intelligence of crows and magpies"
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

// ---------- 3. Local static servers ----------
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/json; charset=utf-8",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

const serve = (dir, { spa = false, extra } = {}) =>
  new Promise((resolveServer) => {
    const absDir = resolve(dir);
    const s = createServer((req, res) => {
      const p = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      if (extra) {
        const r = extra(p);
        if (r) {
          res.writeHead(200, {
            "content-type": "text/html; charset=utf-8",
            "access-control-allow-origin": "*",
          });
          return res.end(r);
        }
      }
      let f = normalize(join(absDir, p));
      if (!f.startsWith(absDir)) {
        res.writeHead(403);
        return res.end();
      }
      if (existsSync(f) && statSync(f).isDirectory()) f = join(f, "index.html");
      if (!existsSync(f) && spa) f = join(absDir, "app/index.html");
      if (!existsSync(f)) {
        res.writeHead(404);
        return res.end();
      }
      res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
      res.end(readFileSync(f));
    }).listen(0, "127.0.0.1", () =>
      resolveServer({ s, origin: `http://127.0.0.1:${s.address().port}` }),
    );
  });

const json = (route, body, status = 200) =>
  route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

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

const ext = await serve(extDistDir);
const web = await serve(webDistDir, {
  spa: true,
  extra: (p) => {
    if (p === "/__c/2/article.html") return heroArticleHtml();
    return null;
  },
});

const browser = await chromium.launch({
  ...(chromePath ? { executablePath: chromePath } : {}),
  headless: true,
});

try {
  // Capture 1: Chrome extension popup (.popup-card, 2x scale, zero consent banner)
  {
    const ctx = await browser.newContext({ viewport: { width: 420, height: 640 }, deviceScaleFactor: 2 });
    await ctx.route("https://api.sroka.app/**", (route) => {
      const u = new URL(route.request().url());
      if (u.pathname === "/v1/tags") return json(route, { tags: TAGS });
      if (u.pathname === "/v1/tags/suggestions") {
        return json(route, {
          recent: ["birds", "nature", "longreads"],
          frequent: ["tech", "design"],
          current: ["birds", "nature"],
        });
      }
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
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(700);
    const png = await page.locator(".popup-card").screenshot();
    const dest = join(outDir, "ext-saved.png");
    writeFileSync(dest, png);
    console.log(`captured promo/linkedin/assets/ext-saved.png (${png.length} bytes)`);
    await ctx.close();
  }

  // Helper for Web App captures (zero consent banner)
  async function captureWeb(path, { width, height, waitFor, reader = false, scale = 2 }) {
    // Note: sandboxed srcdoc iframes in headless Chromium can clip at deviceScaleFactor > 1,
    // so reader views capture at scale 1 with an enlarged logical viewport for crisp pixels.
    const ctx = await browser.newContext({
      viewport: { width, height },
      deviceScaleFactor: reader ? 1 : scale,
      colorScheme: "light",
    });
    await ctx.route("https://fonts.googleapis.com/**", (r) => r.continue());
    await ctx.route(web.origin + "/v1/**", (route) => {
      const u = new URL(route.request().url());
      const m = u.pathname.match(/^\/v1\/items\/([^/]+)(\/content)?$/);
      if (u.pathname === "/v1/me") {
        return json(route, {
          user: { id: "u1", email: "reader@example.com", name: null, emailVerified: true, createdAt: NOW - 90 * 24 * H },
          stats: { unread: ITEMS.length, archived: 18, favorites: 3, tags: TAGS.length },
          clients: { extension: true, android: true, ios: true },
        });
      }
      if (u.pathname === "/v1/config") {
        return json(route, {
          appOrigin: web.origin,
          minVersions: { android: null, ios: null, extension: null },
          features: {},
          limits: { maxOpsPerPush: 100, maxHtmlBytes: 5e6, maxImportBytes: 5e7 },
        });
      }
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
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(1600);
    } else {
      await page.waitForSelector(waitFor, { timeout: 15000 });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(900);
    }
    const png = await page.screenshot();
    await ctx.close();
    return png;
  }

  // Capture 2: Built @sroka/web light library (1020x680, 2x scale, zero consent banner)
  {
    const png = await captureWeb("/app/", {
      width: 1020,
      height: 680,
      waitFor: "text=How a magpie",
      scale: 2,
    });
    const dest = join(outDir, "web-library.png");
    writeFileSync(dest, png);
    console.log(`captured promo/linkedin/assets/web-library.png (${png.length} bytes)`);
  }

  // Capture 3: Built @sroka/web article reader (1060x820, scale 1 so sandboxed srcdoc iframe never clips)
  {
    const png = await captureWeb(`/app/item/${ITEMS[2].id}`, {
      width: 1060,
      height: 820,
      reader: true,
    });
    const dest = join(outDir, "web-reader.png");
    writeFileSync(dest, png);
    console.log(`captured promo/linkedin/assets/web-reader.png (${png.length} bytes)`);
  }
} finally {
  await browser.close();
  ext.s.close();
  web.s.close();
}

console.log("Prepared all 13 assets in promo/linkedin/assets/.");
