# Sroka — cross-cutting decisions (authoritative; overrides docs/sroka-system-design.md where they differ)

Research briefs with verified snippets: `docs/research/{auth,email,do,parser,ext}.md`.
Exact HTTP/sync contract: `docs/api.md` (written in the foundation step; source of truth = `packages/shared`).

## D1 Scope of this build (web + Chrome extension + backend)
- In: email-OTP auth, account deletion, items (save/list/search/archive/favorite/delete/refresh/progress), tags (add/remove/rename/delete, suggestions),
  "collections" in the UI = My List / Archive / Favorites / per-tag views, parser pipeline (fetch → Readability → sanitize → images → package → R2),
  signed content delivery, web reader, sync push/pull API (for the future mobile apps), Pocket/Instapaper/Netscape import, CSV/JSON export, Chrome extension.
- Later (keep hooks, don't build): Browser Run fallback (behind `BROWSER_RENDER_ENABLED`, off), full zip export archive, FCM, highlights, Turnstile, WebSocket realtime.

## D2 Tooling
- npm workspaces (no pnpm). Node 26, TypeScript ^5.9, ESM everywhere, `"type": "module"`.
- Workspaces: `packages/shared` (`@sroka/shared`), `packages/extractor` (`@sroka/extractor`), `workers/api` (`@sroka/api`), `workers/parser` (`@sroka/parser`), `apps/web` (`@sroka/web`), `apps/extension` (`@sroka/extension`).
- Internal packages are consumed as TS source (`"exports": {".": "./src/index.ts"}`), no build step for packages.
- Tests: vitest. Workers use `@cloudflare/vitest-plugin` (see research/do.md §8). `packages/*` tests run in plain node vitest.
- Pin versions from research briefs: better-auth 1.7.x, hono 4.13.x, drizzle-orm 0.45.x, drizzle-kit 0.31.x, wrangler 4.151.x, zod 4.x, react 19, vite (latest), react-router 7 (data mode), @tanstack/react-query 5, tailwindcss 4 (@tailwindcss/vite), wxt (latest).
- `compatibility_date: "2026-10-01"`, `compatibility_flags: ["nodejs_compat"]` on both Workers.

## D3 Hostnames & routing (one API Worker `sroka-api`)
- `sroka.app`: static assets = landing page at `/`, SPA at `/app/*` (React; Vite `base: "/"` — landing and SPA share hashed bundles under `/assets/*`, see D8). The same Worker ALSO serves `/api/auth/*` and `/v1/*` on this host so the web app is **same-origin** (host-only cookies, no CORS, no cross-subdomain cookies). `run_worker_first: ["/api/*", "/v1/*"]`.
- `api.sroka.app`: `/api/auth/*`, `/v1/*` for the extension and future native apps (bearer tokens). CORS allow-list: `APP_ORIGIN`, `chrome-extension://*`, `moz-extension://*` (bearer only, credentials not needed).
- `c.sroka.app`: signed content delivery only (cookieless). Worker branches on hostname == host of `CONTENT_ORIGIN`.
- Vars: `APP_ORIGIN`, `API_ORIGIN`, `CONTENT_ORIGIN`, `ENVIRONMENT` (`development|production`). Local dev: APP_ORIGIN=`http://localhost:8787`, API_ORIGIN=`http://localhost:8787`, CONTENT_ORIGIN=`http://127.0.0.1:8787` (different origin from localhost → isolation still exercised). Web dev server (vite, port 5173) proxies `/api` and `/v1` to 8787.
- Dev-only var `DEV_ORIGINS` (comma-separated, `.dev.vars`: `DEV_ORIGINS=http://localhost:5173`; unset in production): added to Better Auth `trustedOrigins` (the vite proxy keeps `Origin: http://localhost:5173`) and to the content-route CORS allow-list (`fetch(articleUrl)` from the vite page).
- Local dev runs on a generated `workers/api/wrangler.dev.jsonc` (= `wrangler.jsonc` minus `routes`; `npm run dev -w @sroka/api`). With `routes` present, `wrangler dev` rewrites every request URL to the first route host (`http://sroka.app/…`) and rewrites `Origin`/`Referer` headers mentioning `localhost:8787` to `http://sroka.app`, which breaks Better Auth's origin check (403 `INVALID_ORIGIN`) and the content-host branching. Never run plain `wrangler dev` on `wrangler.jsonc`.

## D4 Auth
- Better Auth + drizzleAdapter(provider sqlite) on D1 binding `DB`; plugins `emailOTP` (otpLength 6, expiresIn 300, allowedAttempts 5, storeOTP "hashed") and `bearer()`. Construct per request (`createAuth(env, ctx)`), never module-global. Session 90 d, updateAge 1 d. Rate limit storage "database".
- `trustedOrigins`: `[APP_ORIGIN, API_ORIGIN, "chrome-extension://<EXT_ID>", ...DEV_ORIGINS]` (EXT_ID = the published extension id; in dev also the unpacked id or `chrome-extension://*` when `ENVIRONMENT=development`).
- Email: Cloudflare Email Sending binding `EMAIL` (`send_email: [{name:"EMAIL"}]`), from `{email: "noreply@sroka.app", name: "Sroka"}`, send in `ctx.waitUntil` with try/catch. If `ENVIRONMENT=development`, ALSO `console.log("[sroka] OTP for <email>: <otp>")` and don't call the binding.
- Optional review account: env `REVIEW_EMAIL` + `REVIEW_OTP` → fixed code for that single email only (custom generateOTP). Unset by default.
- Web uses cookies (same-origin). Extension: sign in via `POST /api/auth/sign-in/email-otp`, read `set-auth-token` response header, store in `chrome.storage.local`, send `Authorization: Bearer`.
- `/v1/*` auth middleware: `auth.api.getSession({headers})` → `userId`; 401 JSON `{error:"unauthorized"}` otherwise.

## D5 Data
- Per-user `LibraryDO` (SQLite DO, class `LibraryDO` in workers/api, binding `LIBRARY`, `getByName(userId)`), schema from design §7.1 (items, tags, item_tags, applied_ops, meta, items_fts). Migrations in constructor via `blockConcurrencyWhile`; the schema version lives in a one-row `_schema(id=1, version)` table — DO SQLite forbids `PRAGMA user_version` (SQLITE_AUTH, verified in workerd). Append-only migration steps (`workers/api/src/do/schema.ts`, currently v2). FTS5 works in DO SQLite but must be maintained manually (research/do.md §2).
- All mutations go through one code path: `applyOps(deviceId, ops)` — the REST convenience endpoints (`POST /v1/items`, `PATCH /v1/items/:id`, …) translate to ops server-side. Every changed row gets `seq = ++meta.seq`.
- LWW per field: op `at` (ms, client clock; server clamps to `now+5min`) compared with per-field `clock` JSON; tie → higher deviceId wins. item_tags LWW per pair with the same `{at, dev}` stamp (`item_tags.dev` column, `pairWins()` in shared).
- Idempotency key = `(device_id, op_id)` in `applied_ops`. Duplicate-`item.add` aliases are stored durably in `item_aliases(client_id → target_id)` (not only per push).
- Tags are identified case-insensitively by `tags.name_key = tagKey(name)` (Unicode lower-case; never SQLite `NOCASE`, which folds ASCII only). Stale offline tag ops are resolved through `tag_renames` and tag tombstones (api.md §8.4).
- FTS: `items_fts` is a **regular** FTS5 table (stores its own copy; rows are small), not contentless — supports `UPDATE`/`DELETE … WHERE rowid=?` (overrides design §7.1 `content=''`).
- D1 (binding `DB`): Better Auth tables + `content` + `jobs` (design §7.2; `devices` later) + `auth_throttle` + `content_refs`, `gc_state` (shared-content GC, D6). Drizzle schema in `workers/api/src/db/schema.ts`, migrations in `workers/api/migrations` (drizzle-kit generate), applied with `wrangler d1 migrations apply sroka`.
- IDs: UUIDv7 (implementation in `@sroka/shared`).
- R2 bucket `sroka-content` (binding `CONTENT`) layout per design §7.3.
- KV `CONFIG` for `/v1/config` and site rules (read-mostly).

## D6 Parser pipeline
- `workers/parser` = Worker `sroka-parser`, consumer of queue `sroka-parse` (DLQ `sroka-parse-dlq`, max_retries 3, batch 5). Producer binding `PARSE_QUEUE` lives in sroka-api.
- Message: `{ userId, itemId, url, rawKey?: string, force?: boolean, parseGen: number }` (type in shared). The DO increments `items.parse_gen` on every enqueue; `markParsed` drops results whose `parseGen` doesn't match (stale job). Captured HTML is first stored at `raw/{userId}/{itemId}.html.gz` by the API; message carries the key only.
- Parser binds: `LIBRARY` DO (`script_name: "sroka-api"`, class `LibraryDO`), `DB`, `CONTENT` (R2), `IMAGES`, `CONFIG`. It calls `stub.markParsed(itemId, result)` RPC on the DO.
- Extraction logic lives in `packages/extractor` (pure, unit-testable, runs in node + workers): normalizeUrl (shared), safeFetch (http/https only, block private/loopback IP literals + localhost + our own hosts, ≤5 redirects tracked manually, 15 s timeout, 5 MB cap), Readability on linkedom, sanitize-html allowlist, image rewriting, fflate package zip with manifest.json (design §7.3).
- Images: Images binding → WebP max width 1600, thumbnail 400; on any Images failure store the original bytes if content-type is image/* (≤10 MB). Max 50 images.
- Shared cache: public content cached in D1 `content` by url_hash + PARSER_VERSION for 7 days; captured (private) content never shared. A cache row counts only if its `meta.json` (metadata for `ParseResult`, written last) exists in R2; `content.parsed_at` is epoch **ms**.
- **Shared-content references and GC** (api.md §9 "Content references / GC"; overrides design §9.3 and the earlier parser-side `ref_count + 1`): the truth is derived from the libraries. Each LibraryDO reports which public content ids its live items reference to D1 `content_refs(content_id, user_id)` through a DO SQLite outbox (`content_ref_outbox`, schema v3): references are marked dirty in the same transaction that changes them (`markParsed` replacing/attaching content, `item.delete`), and a serialized flush recomputes the desired state from `items` and writes `INSERT … ON CONFLICT DO NOTHING` / `DELETE` (at-least-once, idempotent; retried by the alarm). Deleted items are detached immediately (items can't be undeleted — a re-save is a new item that attaches again); a failed re-parse keeps the old content attached; `destroy()` deletes the user's refs and the GC drops refs of user ids no longer in D1. `content.ref_count` is only a cache of the COUNT. Every public R2 dir gets a `content` row (inserted before its R2 writes; `cacheable = 0` unless canonical + `ok`). The parser's weekly cron deletes rows (+ `content/{id}/`) with no refs and `last_used_at` (insert, cache hit, attach/detach) older than 30 days, marking `gc_at` first and re-checking refs before deleting; a cache hit touches `last_used_at` in the same statement as its lookup and skips `gc_at` rows. The GC is a no-op until the one-time backfill (operator-started, see workers/parser/CLAUDE.md) set `gc_state.gc_backfill_done`.

## D7 Content delivery
- Signed path (signature in path so relative `img/…` URLs in article.html keep working):
  `${CONTENT_ORIGIN}/s/{exp}/{sig}/{scope}/{contentId}/{file}` where scope = `p` (public, R2 prefix `content/{contentId}/`) or `u.{userId}` (private, R2 prefix `private/{userId}/{contentId}/`).
  `sig = base64url(HMAC-SHA256(CONTENT_URL_SIGNING_KEY, "{exp}/{scope}/{contentId}"))`, exp = unix seconds, default TTL 24 h. Helpers `signContentPath` / `verifyContentPath` in `@sroka/shared` (WebCrypto).
- Content route: GET only, verify sig + exp, stream from R2; `Access-Control-Allow-Origin`: request `Origin` echoed if it is `APP_ORIGIN` or in `DEV_ORIGINS` (+ `Vary: Origin`), web fetches article.html; public scope `Cache-Control: public, max-age=86400, immutable`; private `private, no-store`; always `X-Content-Type-Options: nosniff`, CSP `default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox`.
- Web reader: fetch article.html text from the signed URL, render inside `<iframe sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox" srcdoc=…>` (**NO allow-same-origin** → opaque origin, no access to the app's cookies/DOM) with injected `<base href="{signed dir}/" target="_blank">`, the theme CSS, one app-authored **nonce'd** inline reader script, and the CSP meta
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src {CONTENT_ORIGIN} data:; style-src 'unsafe-inline'; script-src 'nonce-{nonce}'">` (fresh random nonce per render; article.html is sanitized and has no scripts, so only the reader script runs).
  The reader script talks to the parent only via `postMessage` (parent checks `event.source === iframe.contentWindow`; iframe posts to `"*"` since the parent can't be addressed from an opaque origin — messages carry no secrets): The iframe is the scroll container (fills the reader viewport; no auto-height), so the script sees the real scroll position. Out `{type:"sroka:metrics", progress, anchor}` (progress = scrollTop / (scrollHeight − clientHeight), clamped 0..1; debounced ~500 ms on scroll), parent PATCHes `{progress, progressAnchor}` (throttled, and on leave); in `{type:"sroka:scrollToAnchor", anchor}` to restore position after load. Anchors count `PROGRESS_ANCHOR_SELECTOR` from `@sroka/shared` (same in native apps).

## D8 Clients
- Web (`apps/web`): React 19 + Vite + react-router 7 data mode + TanStack Query + Tailwind v4. Same-origin fetch to `/v1` and `/api/auth` with `credentials: "same-origin"`. Vite multi-page build: `apps/web/index.html` = static landing at `/`, `apps/web/app/index.html` = SPA at `/app/` (react-router `basename: "/app"`). `workers/api` assets dir = `../../apps/web/dist`, `not_found_handling: "none"`, `run_worker_first: true` (every request hits the Worker first — needed for the content-host branching; non-API paths go to `env.ASSETS`); the Worker serves `/app/*` via `env.ASSETS.fetch(req)` and falls back to `/app/index.html` on 404 (SPA deep links). Use the `frontend-design` skill; brand = magpie (black/white with iridescent blue-green accent).
- Extension (`apps/extension`): WXT + React, MV3. Toolbar popup: sign-in (email → code), "Saved ✓" on open + tag input with suggestions, open library. Context menus "Save link to Sroka" / "Save page to Sroka", command `Alt+Shift+S`, badge for current tab, retry queue in `chrome.storage.local`, options: server URL (default `https://api.sroka.app`), "always capture rendered page". host_permissions: `https://api.sroka.app/*` (+ `http://localhost:8787/*` in dev); `optional_host_permissions: ["https://*/*", "http://localhost/*"]` — the options page calls `chrome.permissions.request({origins:[origin + "/*"]})` when a custom server URL is saved. "Open library" opens `${appOrigin}/app/` with `appOrigin` from `GET /v1/config`.

## D9 Conventions
- API errors: `{ error: string, message?: string }` with proper status. JSON camelCase on the wire; snake_case in SQL.
- Zod schemas for every request/response in `@sroka/shared`; Hono validates with them.
- Don't commit secrets. `.dev.vars` (gitignored) holds `BETTER_AUTH_SECRET`, `CONTENT_URL_SIGNING_KEY`; `.dev.vars.example` committed.
- Commit messages: conventional (`feat(api): …`). Each agent commits its own work on its branch.
