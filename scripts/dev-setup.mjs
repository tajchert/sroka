#!/usr/bin/env node
// Local dev bootstrap: creates workers/{api,parser}/.dev.vars from the .example files with random secrets
// (only if missing). Run from the repo root: `node scripts/dev-setup.mjs` (or `npm run dev:setup`).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const secret = () => randomBytes(32).toString("base64url");

for (const w of ["api", "parser"]) {
  const dir = join(root, "workers", w);
  const target = join(dir, ".dev.vars");
  if (existsSync(target)) {
    console.log(`keep   workers/${w}/.dev.vars`);
    continue;
  }
  const text = readFileSync(join(dir, ".dev.vars.example"), "utf8")
    .replace(/^BETTER_AUTH_SECRET=.*$/m, `BETTER_AUTH_SECRET=${secret()}`)
    .replace(/^CONTENT_URL_SIGNING_KEY=.*$/m, `CONTENT_URL_SIGNING_KEY=${secret()}`);
  writeFileSync(target, text);
  console.log(`create workers/${w}/.dev.vars`);
}
