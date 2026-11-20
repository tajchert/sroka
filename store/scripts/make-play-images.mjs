// Google Play graphics generator: icon-512, feature graphic, framed phone screenshots, framed foldable screenshots.
// Inputs: docs/brand/icon.svg and the Compose screenshot-test references (see apps/android/docs/SCREENSHOT_TESTING.md;
// StoreScreenshotTests.kt in feature/library/impl, feature/settings/impl and app). Output: store/google-play/images/.
//
//   SHARP_PREFIX=<dir with node_modules/sharp> node store/scripts/make-play-images.mjs
import { mkdirSync, readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const sharp = createRequire(join(process.env.SHARP_PREFIX ?? process.cwd(), "noop.js"))("sharp");
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const out = join(root, "store/google-play/images");
mkdirSync(out, { recursive: true });

const BLUE = "#1e6f8f", INK = "#15171c", BEAK = "#f2c84b";
const FONT = "Helvetica Neue, Helvetica, Arial, sans-serif";
const icon = readFileSync(join(root, "docs/brand/icon.svg"));

// 1. App icon: full-bleed square tile, 32-bit PNG with alpha channel.
await sharp(icon, { density: 600 }).resize(512, 512).ensureAlpha().png().toFile(join(out, "icon-512.png"));

// 2. Feature graphic 1024x500, no alpha.
const mark = await sharp(icon, { density: 600 }).resize(260, 260).png().toBuffer();
const rounded = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="260" height="260"><rect width="260" height="260" rx="58"/></svg>`);
const tile = await sharp(mark).composite([{ input: rounded, blend: "dest-in" }]).png().toBuffer();
const fg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500">
  <rect width="1024" height="500" fill="${BLUE}"/>
  <text x="400" y="255" font-family="${FONT}" font-size="132" font-weight="800" fill="#fff">Sroka</text>
  <rect x="404" y="285" width="96" height="8" rx="4" fill="${BEAK}"/>
  <text x="402" y="352" font-family="${FONT}" font-size="46" font-weight="500" fill="#fff">Save it now. Read it later.</text>
</svg>`;
await sharp(Buffer.from(fg)).composite([{ input: tile, left: 100, top: 120 }]).flatten({ background: BLUE }).removeAlpha().png().toFile(join(out, "feature-graphic-1024x500.png"));

// 3. Phone screenshots: raw 1080x1920 renders placed in a brand frame with a short headline.
const refs = (dir) => {
  const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]));
  return walk(join(root, dir));
};
const find = (files, name) => files.find((f) => f.includes(`/${name}_`));
const lib = refs("apps/android/feature/library/impl/src/screenshotTestDebug/reference");
const set = refs("apps/android/feature/settings/impl/src/screenshotTestDebug/reference");

const shots = [
  ["01-library", "Save now.\nRead later.", find(lib, "StorePhoneLibraryLight")],
  ["02-saved", "Save from any app\nin one tap", find(lib, "StorePhoneSaved")],
  ["03-search", "Search the full\ntext of everything", find(lib, "StorePhoneSearch")],
  ["04-tags", "Organise with tags", find(lib, "StorePhoneTags")],
  ["05-privacy", "Your library, your\nchoices. No ads.", { crop: find(set, "StorePhoneSettingsTall") }],
  ["06-dark", "Easy on the eyes\nat night", find(lib, "StorePhoneLibraryDark")],
];

const W = 1080, H = 1920, SW = 860, SH = Math.round((SW * 1920) / 1080), SY = 370;
for (const [name, headline, src] of shots) {
  let img;
  if (src.crop) img = sharp(src.crop).extract({ left: 0, top: 3990 - 1920, width: 1080, height: 1920 });
  else img = sharp(src);
  const shot = await img.resize(SW, SH).png().toBuffer();
  const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${SW}" height="${SH}"><rect width="${SW}" height="${SH}" rx="56"/></svg>`);
  const clipped = await sharp(shot).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer();
  const lines = headline.split("\n");
  const text = lines.map((l, i) => `<text x="540" y="${150 + i * 96}" text-anchor="middle" font-family="${FONT}" font-size="84" font-weight="800" fill="#fff">${l}</text>`).join("");
  const bg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="${BLUE}"/><rect x="480" y="${150 + (lines.length - 1) * 96 + 40}" width="120" height="8" rx="4" fill="${BEAK}"/>${text}</svg>`;
  await sharp(Buffer.from(bg)).composite([{ input: clipped, left: (W - SW) / 2, top: SY }]).flatten({ background: INK }).removeAlpha().png({ compressionLevel: 9 }).toFile(join(out, `phone-${name}.png`));
}
// 4. Foldable screenshots (Play: 3-8, incl. unfolded 1:1, unfolded 4:3, outer screen 10:16). Same brand frame as the
// phone shots, adapted per canvas. Each raw render is scaled to `sw` wide and centred under the headline; the canvas
// is exactly 1:1 / 4:3 / 10:16, every side 960-3840 px. Raw renders: unfolded 1520x1520 (1:1) and 1760x1320 (4:3), folded 1080x1728 (10:16).
const app = refs("apps/android/app/src/screenshotTestPlayDebug/reference");
const foldables = [
  // [file name, headline, source, canvas w, canvas h, shot width, shot top, headline font size, headline baseline y, corner radius]
  ["01-unfolded-library", "Made for unfolded screens", find(app, "StoreFoldUnfoldedLibrary"), 1920, 1920, 1480, 330, 92, 160, 48],
  ["02-unfolded-tags", "Tags and their articles, together", find(app, "StoreFoldUnfoldedTags"), 2160, 1620, 1760, 250, 84, 130, 48],
  ["03-folded-library", "Save now.\nRead later.", find(lib, "StoreFoldedLibraryLight"), 1200, 1920, 920, 400, 84, 150, 56],
  ["04-unfolded-search", "Search the full text of everything", find(app, "StoreFoldUnfoldedSearch"), 2160, 1620, 1760, 250, 84, 130, 48],
  ["05-unfolded-dark", "Easy on the eyes at night", find(app, "StoreFoldUnfoldedLibraryDark"), 1920, 1920, 1480, 330, 92, 160, 48],
];
for (const [name, headline, src, CW, CH, fw, top, fs, y0, rx] of foldables) {
  const meta = await sharp(src).metadata();
  const fh = Math.round((fw * meta.height) / meta.width);
  const shot = await sharp(src).resize(fw, fh).png().toBuffer();
  const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${fw}" height="${fh}"><rect width="${fw}" height="${fh}" rx="${rx}"/></svg>`);
  const clipped = await sharp(shot).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer();
  const lines = headline.split("\n");
  const step = Math.round(fs * 1.14);
  const text = lines.map((l, i) => `<text x="${CW / 2}" y="${y0 + i * step}" text-anchor="middle" font-family="${FONT}" font-size="${fs}" font-weight="800" fill="#fff">${l}</text>`).join("");
  const bar = `<rect x="${CW / 2 - 60}" y="${y0 + (lines.length - 1) * step + 40}" width="120" height="8" rx="4" fill="${BEAK}"/>`;
  const bg = `<svg xmlns="http://www.w3.org/2000/svg" width="${CW}" height="${CH}"><rect width="${CW}" height="${CH}" fill="${BLUE}"/>${bar}${text}</svg>`;
  await sharp(Buffer.from(bg)).composite([{ input: clipped, left: Math.round((CW - fw) / 2), top }]).flatten({ background: INK }).removeAlpha().png({ compressionLevel: 9 }).toFile(join(out, `foldable-${name}.png`));
}
console.log("done");
