# e2e (fix/integration)

## Report
The merged system now runs end to end locally. One bug was blocking it: the local dev setup broke sign-in and the content host. After fixing it, the new `scripts/e2e-local.sh` passes all 159 checks. Typecheck passes, and the api tests (57) and parser tests (15) pass.

**Branch:** `fix/integration`

**Commits:**
- `29c7b28` fix(api): local dev stack without routes rewrite; dev setup and e2e script
- `7a44e43` docs: reconcile decisions/api.md with merged code; local stack docs; ledger

**The bug fixed**
- Because `workers/api/wrangler.jsonc` has production `routes`, `wrangler dev` sent every request to `http://sroka.app/…`. It also rewrote `Origin: http://localhost:8787` to `http://sroka.app`.
- Effects: sign-in failed with 403 `INVALID_ORIGIN`, and requests to the content host (127.0.0.1:8787) were not recognised.
- Fix: `npm run dev -w @sroka/api` now runs `workers/api/scripts/dev.mjs`. It writes `wrangler.dev.jsonc` (a copy of `wrangler.jsonc` without `routes`, gitignored). It then starts the api and parser together in one `wrangler dev`, with `-c wrangler.dev.jsonc -c ../parser/wrangler.jsonc`.
- Because both run in one process, the parser uses the same local D1, R2 and Durable Object state. The queue consumer runs locally, and the shared D1 cache hits on reruns.
- The production config is unchanged.

**Added**
- `scripts/dev-setup.mjs` creates both `.dev.vars` files with random secrets. Root `npm run dev:setup` runs it, applies the local D1 migrations and builds the web app.
- `scripts/e2e-local.sh`, run with `npm run e2e:local` and `DEV_LOG=<wrangler log>`. It uses bash, curl, jq and node, and exits non-zero on the first failure. It checks:
  - **Pages:** landing, `/app/`, a deep link and an asset; health, config and CORS preflight.
  - **Sign-in:** reads the OTP from the dev log, wrong-code 400, both the bearer token and the cookie against `/v1/me`.
  - **Saves:** the Wikipedia magpie article, a Cloudflare blog post, and an HTML capture containing a remote image. It polls until the parse finishes.
  - **Content:** article, images, thumbnail and package from 127.0.0.1:8787 (the content host), with CSP, nosniff, CORS and cache headers. Image bytes must match the content-type. A tampered signature gives 403, a POST gives 405.
  - **Tags and items:** add, rename, case-insensitive merge, delete and suggestions; favorite, progress, title, archive and empty-PATCH 400.
  - **Filters:** state, tag, `q` (including FTS special characters), domain, url lookup, bad cursor, cursor paging, sort, and a refresh.
  - **Sync:** push/pull with a fake device, including an alias, a replayed push, rejected ops and a deleted item.
  - **Vite proxy (when port 5173 is up):** sign-in, `/v1/me` with cookie and account deletion through it.
  - **Account deletion:** the token and cookie stop working, the private content returns 404, and signing up again with the same email gives an empty account.
  - It waits out Better Auth rate limits on 429.
- `scripts/sniff-image.mjs` checks that an image's bytes match its declared type.

**Images:** the local Images binding converts with sharp, so the stored images and thumbnails are real WebP. I did not force the fallback in the running stack. An existing parser test covers it, and the content route serves the original type from the R2 metadata.

**Docs**
- `docs/decisions.md`:
  - D3: the local dev rule above.
  - D5: `_schema` table instead of `PRAGMA user_version`.
  - D6: the parser owns `ref_count`, `meta.json` marks a valid cache entry, `parsed_at` is in milliseconds.
  - D8: Vite base `/` and `run_worker_first: true`.
- `docs/api.md`: reconciled the contract issues from the api-core, api-platform and parser handoffs:
  - re-add always moves `savedAt` forward;
  - `isFavorite` is stamped only when the add op sets it;
  - merged tags keep each pair's own stamp;
  - PATCH is atomic;
  - `rejected` is not in op order;
  - the pull RPC wrapper and the sweep RPCs;
  - schema v2 columns;
  - tombstones expire by server time;
  - the sign-in rate limit;
  - ref-counting.
- `CLAUDE.md` and `workers/api/CLAUDE.md` now cover the local stack and the e2e script; `docs/ledger.md` rows are updated.

**Remaining issues**
1. `/v1/exports` and imports are still stubs (another agent owns them). The e2e script skips exports while the route returns 404.
2. A captured page's `data:` images are dropped by design. Remote images in captures work.
3. Better Auth rate limits (3 OTP sends per minute, 3 sign-ins per 10 s per IP) slow down quick reruns of the e2e script by up to about 60 s.
4. I did not check the web reader iframe or the extension in a real browser; only HTTP-level checks were done.

All background processes (wrangler dev, vite) are stopped and ports 8787 and 5173 are free. Logs are in `/private/tmp/claude-501/sroka-e2e/`.

Files are in `/Users/mtajchert/coding/priv/sroka/.claude/worktrees/wf_b2284ffb-4ee-2/`:
- `workers/api/scripts/dev.mjs`
- `scripts/e2e-local.sh`
- `scripts/dev-setup.mjs`
- `scripts/sniff-image.mjs`

## Review
**Review of `fix/integration` against `main`: four real defects, none high severity**

The diff is 12 files: `dev.mjs`, the three new scripts, `package.json`, `.gitignore` and docs. The production config and runtime code are unchanged, so there is no correctness or security regression for users. All four defects are in the dev and e2e tooling. I reviewed by reading the diff only and ran nothing.

1. **`scripts/e2e-local.sh:53-60, 349-351` (also 330-331) — medium.**
   - **Problem:** `read_otp` takes the newest log line for the email straight away and returns on the first match. At line 349 the same `$EMAIL` already has a line from the first sign-in (line 159). If the new OTP is not yet written to the log when `read_otp` runs, it returns the old, already-used code. The re-sign-up at line 351 then fails with 400. The same thing happens on any rerun with a fixed `EMAIL=` against a log that hasn't been reset. So the script can fail at random.
   - **Fix:** record the matching line count (or `wc -c "$DEV_LOG"`) before `send_otp`. Have `read_otp` only accept a match after that point, or one that differs from the previous OTP.

2. **`workers/api/scripts/dev.mjs:33-34` — low.**
   - **Problem:** if a block comment is never closed, `text.indexOf("*/", i + 2)` returns -1. That sets `i = 0`, so parsing starts over and loops forever. `npm run dev` hangs with no error.
   - **Fix:** if the index is -1, throw an "unterminated comment" error.

3. **`workers/api/scripts/dev.mjs:37` — low.**
   - **Problem:** the trailing-comma regex `/,(\s*[}\]])/g` runs on the whole output, including the contents of strings. A config value such as `", ]"` would be silently changed in `wrangler.dev.jsonc`.
   - **Fix:** drop trailing commas inside the string-aware scanner, or use `jsonc-parser` or wrangler's own parser.

4. **`workers/api/scripts/dev.mjs:48-51` — low.**
   - **Problem:** it only checks that `workers/api/.dev.vars` exists. If `workers/parser/.dev.vars` is missing, the parser starts with the production `APP_ORIGIN`, `API_ORIGIN` and `CONTENT_ORIGIN` from `parser/wrangler.jsonc`. It then works against the production URLs, and nothing reports it.
   - **Fix:** check for `../parser/.dev.vars` as well, with the same error message.

Two minor robustness points, not real defects:
- **`scripts/e2e-local.sh:145`:** if the landing page has no `/assets/app-*.js`, the `grep | head` assignment fails under `set -euo pipefail`. The script then exits with no `FAIL` message. Fix: add `|| fail "no app asset"`.
- **`dev.mjs:54`:** under `npm run`, Ctrl-C reaches wrangler twice, once from the terminal and once from the forwarded `child.kill`. This only affects how it shuts down.

I found nothing wrong in `scripts/dev-setup.mjs` or `scripts/sniff-image.mjs`. Generating separate secrets for api and parser is fine, because the parser doesn't use `BETTER_AUTH_SECRET` or `CONTENT_URL_SIGNING_KEY`.

Files are in `/Users/mtajchert/coding/priv/sroka/.claude/worktrees/wf_b2284ffb-4ee-2/`:
- `scripts/e2e-local.sh`
- `workers/api/scripts/dev.mjs`
