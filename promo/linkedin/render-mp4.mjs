#!/usr/bin/env node
// Deterministic 60fps Playwright -> ffmpeg H.264 MP4 renderer for promo/linkedin/index.html.
//
// Reads `{ durationMs, width, height }` from `window.__ANIMATION__` and drives
// `window.__ANIMATION__.setTime(ms)` frame-by-frame into ffmpeg (`image2pipe` PNG -> H.264 MP4).
//
// Env overrides:
//   FPS=30          Frame rate (default: 60)
//   OUT=path.mp4    Output MP4 path (default: promo/linkedin/sroka-linkedin.mp4)
//   PW_CORE=...     Path to playwright-core module
//   CHROME=...      Path to Chromium executable
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const promoDir = fileURLToPath(new URL("./", import.meta.url));
const indexHtml = join(promoDir, "index.html");
if (!existsSync(indexHtml)) {
  throw new Error(`Missing animation page: ${indexHtml}`);
}

const fps = Number.parseInt(process.env.FPS || "60", 10);
if (!Number.isFinite(fps) || fps <= 0) {
  throw new Error(`Invalid FPS value: ${process.env.FPS}`);
}

const outPath = process.env.OUT ? resolve(process.env.OUT) : join(promoDir, "sroka-linkedin.mp4");
mkdirSync(dirname(outPath), { recursive: true });

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
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

function startServer(dir) {
  const absDir = resolve(dir);
  return new Promise((resolveServer) => {
    const server = createServer((req, res) => {
      const p = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      let filePath = normalize(join(absDir, p));
      if (!filePath.startsWith(absDir)) {
        res.writeHead(403);
        return res.end();
      }
      if (existsSync(filePath) && statSync(filePath).isDirectory()) {
        filePath = join(filePath, "index.html");
      }
      if (!existsSync(filePath)) {
        res.writeHead(404);
        return res.end();
      }
      res.writeHead(200, { "content-type": MIME[extname(filePath)] || "application/octet-stream" });
      res.end(readFileSync(filePath));
    }).listen(0, "127.0.0.1", () => {
      resolveServer({ server, origin: `http://127.0.0.1:${server.address().port}` });
    });
  });
}

const { server, origin } = await startServer(promoDir);
const browser = await chromium.launch({
  ...(chromePath ? { executablePath: chromePath } : {}),
  headless: true,
});

try {
  const ctx = await browser.newContext({
    viewport: { width: 1080, height: 1080 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();

  page.on("pageerror", (err) => {
    console.error("[pageerror]", err);
  });

  await page.goto(`${origin}/index.html?capture=1`, { waitUntil: "networkidle" });
  await page.evaluate(async () => {
    if (window.__ANIMATION__?.ready) await window.__ANIMATION__.ready;
    if (document.fonts) await document.fonts.ready;
  });

  // Fail loudly if Outfit failed to load (e.g., offline render) instead of silently falling back to system-ui
  const fontLoaded = await page.evaluate(() => (document.fonts ? document.fonts.check('800 84px Outfit') : true));
  if (!fontLoaded && process.env.ALLOW_FONT_FALLBACK !== "1") {
    throw new Error("Outfit webfont failed to load. Check network access or set ALLOW_FONT_FALLBACK=1 to override.");
  }

  // Wait for every <img> to finish loading with valid dimensions
  await page.waitForFunction(
    () => {
      const imgs = Array.from(document.querySelectorAll("img"));
      return imgs.every((img) => img.complete && img.naturalWidth > 0);
    },
    null,
    { timeout: 30000 },
  );

  const meta = await page.evaluate(() => {
    const anim = window.__ANIMATION__;
    if (!anim || typeof anim.setTime !== "function" || !Number.isFinite(anim.durationMs)) {
      throw new Error("window.__ANIMATION__ with { durationMs, width, height, setTime } is required");
    }
    return {
      durationMs: anim.durationMs,
      width: anim.width || 1080,
      height: anim.height || 1080,
    };
  });

  if (meta.width !== 1080 || meta.height !== 1080) {
    await page.setViewportSize({ width: meta.width, height: meta.height });
  }

  const totalFrames = Math.max(1, Math.round((meta.durationMs / 1000) * fps));
  console.log(
    `Rendering ${totalFrames} frames (${(meta.durationMs / 1000).toFixed(2)}s @ ${fps}fps, ${meta.width}x${meta.height}) -> ${outPath}`,
  );

  const ffmpegArgs = [
    "-y",
    "-f",
    "image2pipe",
    "-vcodec",
    "png",
    "-framerate",
    String(fps),
    "-i",
    "-",
    "-vf",
    "scale=out_color_matrix=bt709:out_range=tv,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709",
    "-c:v",
    "libx264",
    "-profile:v",
    "high",
    "-level",
    "4.2",
    "-pix_fmt",
    "yuv420p",
    "-colorspace",
    "bt709",
    "-color_primaries",
    "bt709",
    "-color_trc",
    "bt709",
    "-crf",
    "17",
    "-preset",
    "slow",
    "-movflags",
    "+faststart",
    "-an",
    outPath,
  ];

  const ff = spawn("ffmpeg", ffmpegArgs, { stdio: ["pipe", "ignore", "pipe"] });
  let ffStderr = "";
  ff.stderr.on("data", (chunk) => {
    ffStderr += chunk.toString();
  });

  let ffFailed = null;
  const ffExitPromise = new Promise((resolveExit, rejectExit) => {
    ff.on("error", (err) => {
      ffFailed = err;
      rejectExit(err);
    });
    ff.on("close", (code, signal) => {
      if (code === 0) {
        resolveExit(0);
      } else {
        const err = new Error(
          `ffmpeg exited with code ${code}${signal ? ` (signal ${signal})` : ""}\n${ffStderr.trim()}`,
        );
        ffFailed = err;
        rejectExit(err);
      }
    });
  });
  // Prevent unhandled rejection if ffmpeg exits before we await ffExitPromise
  ffExitPromise.catch(() => {});

  ff.stdin.on("error", (err) => {
    if (!ffFailed) ffFailed = err;
  });

  const startMs = Date.now();
  for (let frame = 0; frame < totalFrames; frame++) {
    if (ffFailed) throw ffFailed;

    const tMs = (frame / fps) * 1000;
    await page.evaluate((ms) => {
      window.__ANIMATION__.setTime(ms);
    }, tMs);
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())));

    const png = await page.screenshot({ type: "png" });
    if (!ff.stdin.write(png)) {
      await Promise.race([once(ff.stdin, "drain"), ffExitPromise]);
    }

    if ((frame + 1) % fps === 0 || frame + 1 === totalFrames) {
      const elapsedSec = ((Date.now() - startMs) / 1000).toFixed(1);
      const pct = (((frame + 1) / totalFrames) * 100).toFixed(0);
      console.log(`  frame ${frame + 1}/${totalFrames} (${pct}%, ${elapsedSec}s elapsed)`);
    }
  }

  ff.stdin.end();
  await ffExitPromise;

  const sizeBytes = statSync(outPath).size;
  const sizeMb = (sizeBytes / (1024 * 1024)).toFixed(2);
  console.log(`\nWrote ${outPath} (${sizeBytes} bytes / ${sizeMb} MB)`);

  try {
    const probe = execFileSync(
      "ffprobe",
      [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,profile,level,width,height,pix_fmt,color_space,color_primaries,color_transfer,r_frame_rate,nb_frames:format=duration,bit_rate,size",
        "-of",
        "default=noprint_wrappers=1",
        outPath,
      ],
      { encoding: "utf8" },
    );
    console.log("ffprobe summary:\n" + probe.trim());
  } catch (err) {
    console.warn("ffprobe check skipped:", err.message);
  }

  await ctx.close();
} finally {
  await browser.close();
  server.close();
}
