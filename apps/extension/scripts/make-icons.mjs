// One-off generator: node apps/extension/scripts/make-icons.mjs (needs `sharp`, not a dependency; output is committed).
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="i" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0d9488"/><stop offset=".45" stop-color="#22b8cf"/>
      <stop offset=".75" stop-color="#6ee7b7"/><stop offset="1" stop-color="#38bdf8"/>
    </linearGradient>
  </defs>
  <rect width="128" height="128" rx="28" fill="#0a0a0a"/>
  <!-- tail, long and iridescent -->
  <path d="M20 104 C34 86 50 72 70 62 L80 78 C60 86 40 96 20 104Z" fill="url(#i)"/>
  <!-- body -->
  <path d="M44 74 C42 52 56 36 76 36 C92 36 100 48 98 60 C96 74 82 86 66 86 C56 86 47 82 44 74Z" fill="#fafafa"/>
  <!-- wing -->
  <path d="M52 66 C60 56 78 54 90 62 C84 76 70 82 58 78 C54 76 52 72 52 66Z" fill="url(#i)"/>
  <!-- head dark cap + beak + eye -->
  <path d="M76 36 C90 34 100 42 100 54 L90 50 C88 42 82 38 76 36Z" fill="#0a0a0a" stroke="#fafafa" stroke-width="2"/>
  <path d="M98 50 L112 56 L98 62Z" fill="#fafafa"/>
  <circle cx="88" cy="48" r="3" fill="#0a0a0a"/>
</svg>`;

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "public", "icon");
mkdirSync(out, { recursive: true });
writeFileSync(join(here, "..", "assets", "icon.svg"), svg);
for (const n of [16, 32, 48, 128]) {
  await sharp(Buffer.from(svg)).resize(n, n).png().toFile(join(out, `${n}.png`));
}
console.log("icons written");
