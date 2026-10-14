#!/usr/bin/env node
// Usage: node scripts/sniff-image.mjs <file> <declared-content-type>
// Exits non-zero if the file's magic bytes don't match the declared image type (used by scripts/e2e-local.sh).
import { readFileSync } from "node:fs";

const [file, declared = ""] = process.argv.slice(2);
const b = readFileSync(file);
const hex = (s, e) => b.subarray(s, e).toString("hex");
const ascii = (s, e) => b.subarray(s, e).toString("latin1");
const actual =
  ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP" ? "image/webp"
  : hex(0, 3) === "ffd8ff" ? "image/jpeg"
  : hex(0, 8) === "89504e470d0a1a0a" ? "image/png"
  : ascii(0, 4) === "GIF8" ? "image/gif"
  : ascii(4, 12) === "ftypavif" ? "image/avif"
  : "unknown";
const type = declared.split(";")[0].trim().toLowerCase();
if (actual !== type) {
  console.error(`declared ${type} but bytes are ${actual}`);
  process.exit(1);
}
console.log(actual);
