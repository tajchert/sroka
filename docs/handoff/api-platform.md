# api-platform (feat/api-platform)

## Implementation report
Branch: `feat/api-platform`. One commit, `1f64edb`: "feat(api): platform — Better Auth, D1 schema/migrations, CORS, auth middleware, content route, account/config".

**Implemented**
- **Auth:** `src/auth.ts` has `createAuth(env, ctx)`, built per request.
  - Plugins and settings follow D4: emailOTP and bearer, 90-day sessions, database rate limit, and a 3/min rule on `send-verification-otp`.
  - Trusted origins are APP, API, `EXT_ID` (new optional env var), DEV_ORIGINS, and `chrome-extension://*` in dev.
  - `REVIEW_EMAIL` and `REVIEW_OTP` give one fixed code for that single email.
- **Email:** `src/email.ts` logs `[sroka] OTP for …` in development and does not call the binding. In production it sends through `EMAIL`. It also records the last OTP per email in the exported `otpSink` Map, which the tests read.
- **D1 and migrations:**
  - `src/db/auth-schema.ts` was generated with the Better Auth CLI. `src/db/schema.ts` adds `content` and `jobs` (with `format` and `skipped`).
  - Migration is `migrations/0000_warm_kang.sql`. The auth schema file is at `src/db/auth-schema.ts`, per the package script and CLAUDE.md, not `src/auth-schema.ts`.
  - `auth.cli.ts` and `drizzle.config.ts` are in place.
- **`src/index.ts`:**
  - Requests whose host equals the `CONTENT_ORIGIN` host go to the content handler only.
  - CORS on `/api/*` and `/v1/*` follows §2 (APP, DEV_ORIGINS, `chrome-extension://`, `moz-extension://`; `set-auth-token`, `X-Retry-After` and the other headers exposed).
  - `/api/auth/*` goes to Better Auth. `/v1/health` and `/v1/config` are public. After them, an auth middleware sets `c.var.userId` or returns 401.
  - `/app/*` is served from assets with an `/app/index.html` fallback. Other non-API paths fall through to assets, and unknown `/v1/*` or `/api/*` paths get a JSON 404.
  - `LibraryDO` is exported.
- **Routes:**
  - `src/routes/content.ts`: signature and expiry check, streaming from R2, headers and CORS per D7, `If-None-Match` 304, HEAD, OPTIONS, 403/404/405.
  - `src/routes/account.ts`: `GET /v1/me`. `DELETE /v1/account` requires `{confirm:"DELETE"}`, calls the DO `destroy()`, deletes `jobs` and the Better Auth rows (session, account, verification, user), then wipes the R2 prefixes `private/{uid}/`, `raw/{uid}/` and `uploads/{uid}/` in `waitUntil`.
  - `src/routes/config.ts`: KV `CONFIG` merged over defaults, `appOrigin` always from env, `Cache-Control: public, max-age=300`.
- **Other files:** `src/assets.ts` holds the asset fallback. `src/env.ts` adds `EXT_ID` and an `AppEnv` type with `Variables.userId`.
- **Stubs:** empty Hono apps in `src/routes/{items,tags,sync,imports,exports}.ts`, to be replaced at merge.

**Not implemented**
- Per-user `/v1` soft rate limits (api.md §14) were not built.
- I did not touch `wrangler.jsonc` or `vitest.config.ts`.
- I did not run `wrangler dev` or a deploy dry-run.

**Tests**
- Typecheck is clean.
- vitest: 3 files, 14 tests, all passing.
- They cover:
  - 401 without auth, and public health and config.
  - The OTP flow end to end, with bearer and cookie both reaching `/v1/me`.
  - A wrong OTP, the review account, and the 3/min OTP rate limit.
  - Account delete.
  - Content signature, expiry, malformed paths, 404/405, ETag/304, and public versus private cache headers.
  - CORS preflight for the extension, moz-extension, the app origin and a foreign origin.
- Test output shows "RPC receiver does not implement stats/destroy" uncaught-exception lines. They come from the placeholder `LibraryDO`, are swallowed by the handlers, and should disappear once the real DO lands.

**CONTRACT ISSUES**
- `LibraryDO.stats()` (for `/v1/me`) is not in the §15 RPC list. I call it if present and fall back to zeros. The DO owner must implement `stats(): {unread, archived, favorites, tags}`.
- The contract does not say whether the route sub-apps carry their own path prefix.

**Notes for the integrator**
- Sub-apps are mounted with prefixes. Their routes must be relative, for example `itemsRoutes.get("/:id")`.

  | Mount | Sub-app |
  |---|---|
  | `/v1/items` | `itemsRoutes` |
  | `/v1/tags` | `tagsRoutes` |
  | `/v1/sync` | `syncRoutes` |
  | `/v1/imports` | `importsRoutes` |
  | `/v1/exports` | `exportsRoutes` |

- If the other agents wrote full paths, change the mounts to `app.route("/v1", …)`.
- Route modules should type their apps as `Hono<AppEnv>` (from `../env.ts`) to get `c.var.userId`.
- `LibraryDO.destroy()` must exist. `/v1/account` calls it and tolerates only the "does not implement" error.
- I added no dependencies.
- The test helper applies `migrations/*.sql` through a Vite `?raw` glob, so new drizzle migrations are picked up automatically.
- `otpSink` is module state read by the tests, written only when `ENVIRONMENT=development`.

## Review
**Review of `feat/api-platform` (commit 1f64edb): 2 medium, 5 low, no high**

I found no auth bypass. The CORS allow-list, signature checks, the 401 middleware, the OTP flow and the config route all match api.md §1–3, §10, §12 and D3/D4/D7. The two medium findings are the SPA deep-link fallback, which is likely but not confirmed by a run, and account delete, which can strand a user.

1. **MED (likely; confirm with `wrangler dev`): SPA deep links redirect to `/app/` and lose the route.** `workers/api/src/assets.ts:8-9`
   - **Problem:** the fallback calls `ASSETS.fetch` on `/app/index.html`. Under the default assets `html_handling: "auto-trailing-slash"`, a request for `/folder/index.html` gets a 307 redirect to `/folder/`. So `/app/items/123` returns a 307 to `/app/` instead of the shell, and the client router never sees the deep path. No test covers assets.
   - **Fix:** fetch `new URL("/app/", req.url)`, or set `html_handling: "none"` in `wrangler.jsonc`. Then add a test that `GET /app/some/deep/path` returns 200 HTML with the original URL kept.

2. **MED: account delete is not atomic and can leave an orphaned account that cannot retry.** `workers/api/src/routes/account.ts:64-68` and `:78-83`
   - **Problem:** the five D1 deletes are separate statements. If one fails after the session delete (line 65) but before the user delete (line 68), the request returns 500. The user is now signed out (401 on retry), but the user row, account rows and `jobs` remain. The R2 wipe in `waitUntil` never starts, because it runs only after `deleteAccountData` succeeds.
   - **Fix:** run the D1 deletes in one `db.batch([...])`, with the session delete last or relying on its `ON DELETE CASCADE`. Start the R2 wipe before or independently of the D1 step, or make the route safe to retry.

3. **LOW: the verification-row delete matches other users' rows.** `workers/api/src/routes/account.ts:67`
   - **Problem:** `like(identifier, '%' + email + '%')` treats `_` and `%` in the email as wildcards, and it also matches substrings. Deleting `bob@x.com` also deletes the pending OTP rows of `alice.bob@x.com`. Deleting `a_b@x.com` matches `aXb@x.com`.
   - **Fix:** match exact identifiers, `inArray(identifier, ["sign-in-otp-"+email, "email-verification-otp-"+email, "forget-password-otp-"+email])`, or use `LIKE` with escaped wildcards and an anchored `'%-otp-' || email`.

4. **LOW: the R2 wipe is best-effort only, so private data can be left behind.** `workers/api/src/routes/account.ts:79-83`
   - **Problem:** paging through `list` and `delete` inside `waitUntil` is capped at about 30 s after the response. A large library under `private/{uid}/` or `raw/{uid}/` can be cut off, and there is no retry or sweep. Parse jobs already in flight (`markParsed`, R2 writes) can also recreate `private/{uid}/…` objects and DO storage after `destroy()`.
   - **Fix:** record a deletion tombstone, for example a `jobs` row with kind `account_delete` or a KV key, and have a cron or queue consumer finish and recheck the prefixes. The parser and `markParsed` should drop work for deleted users.

5. **LOW: the content host serves the landing page and static assets, not 404.** `workers/api/wrangler.jsonc:19`
   - **Problem:** api.md §2 says the content host serves the content route only, "everything else 404". But `run_worker_first` lists only `/api/*`, `/v1/*` and `/app/*`. On `c.sroka.app`, paths like `/`, `/assets/*.js` and `/favicon.ico` are served directly from assets, and the host branch in `index.ts:20-23` never runs.
   - **Fix:** set `run_worker_first: true`, or add `"/*"`, and serve assets from the worker on the app host only. Alternatively, accept this and document it.

6. **LOW: SPA fallback over-matches.** `workers/api/src/assets.ts:7`
   - **Problem:** `pathname.startsWith("/app")` also matches `/apple-touch-icon.png` and `/application.json`. A missing root file then returns the SPA shell with status 200 instead of 404.
   - **Fix:** use `pathname === "/app" || pathname.startsWith("/app/")`.

7. **LOW: the fixed review OTP can be brute-forced across OTP requests.** `workers/api/src/auth.ts:64-68`
   - **Problem:** with a constant code, every send-OTP gives 5 more guesses at the same secret. At 3 sends/min per IP, an attacker using many IPs can work through a 6-digit space (10^6) in hours. This is inherent to D4, but nothing narrows it.
   - **Fix:** require `REVIEW_OTP` to be unset in production unless deliberately enabled, and log or alert on failed sign-ins for `REVIEW_EMAIL`. Optionally lower `allowedAttempts` for that email.

**Contract notes (not defects):**
- The contract issues the implementer raised are valid. `stats()` is not in the §15 RPC list, but §15 does list stats as internal to `workers/api`, so the DO owner must add it. Mount prefixes have to be reconciled at merge.
- Unknown `/v1/*` paths return 401 rather than 404 when the request has no auth. This is acceptable.
- The `content_url` index is missing `DESC` on `parsed_at`. It has no functional impact.
- The per-user soft limits in §14 are optional ("MAY"), so leaving them out is not a violation.

**Tests:** I read the tests and they look sound and match the report. I did not re-run them. No tests cover the asset fallback (#1) or failures part-way through account delete (#2).

Files reviewed (on the branch, via `git show`):
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/index.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/auth.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/email.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/env.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/middleware/auth.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/routes/account.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/routes/config.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/routes/content.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/assets.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/src/db/schema.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/migrations/0000_warm_kang.sql`
- `/Users/mtajchert/coding/priv/sroka/workers/api/wrangler.jsonc`
- `/Users/mtajchert/coding/priv/sroka/workers/api/vitest.config.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/test/platform/helpers.ts`
- `/Users/mtajchert/coding/priv/sroka/workers/api/test/platform/auth.test.ts`

## Fix report
Branch: `feat/api-platform-review-fixes`, one commit on top of 1f64edb: `0ec3c13` (`fix(api): review fixes — SPA fallback, atomic account delete, exact OTP row match`).

`feat/api-platform` is checked out in another worktree (`.../wf_2331d63d-83a-2`), so I couldn't check it out here. I branched from it instead. To land the fixes, fast-forward `feat/api-platform` to `0ec3c13`, or cherry-pick it.

**Fixed**
- **#1 (MED), SPA deep links:** `src/assets.ts` now falls back to `/app/` instead of `/app/index.html`, which avoids the 307 redirect. I confirmed it only with a fake `ASSETS` in a test, not with `wrangler dev`.
- **#2 (MED), account delete:** `src/routes/account.ts` now runs the D1 deletes in one `db.batch`, with the session delete last.
  - The R2 wipe starts through an `afterLibraryWipe` callback, right after the DO `destroy()` and before the D1 batch. If the batch fails, the user stays signed in and can retry.
- **#3 (LOW), verification rows:** the delete now matches exact identifiers (`sign-in-otp-`, `email-verification-otp-`, `forget-password-otp-` plus the email) with `inArray`. The `LIKE` wildcards are gone.
- **#5 (LOW), content host:** `wrangler.jsonc` now has `run_worker_first: true`, so the host branch runs for every path on `c.sroka.app`. The notFound handler serves assets for the app host.
- **#6 (LOW), over-matching:** the fallback now requires `pathname === "/app"` or a `/app/` prefix.

**Skipped**
- **#4 (LOW), R2 wipe is best-effort:** a proper fix needs a tombstone plus a cron or queue sweeper, and parser and `markParsed` changes in files I don't own. Remaining gap: a very large library, or an in-flight parse job, can leave `private/{uid}/` objects behind.
- **#7 (LOW), fixed review OTP:** this is inherent to D4. It is mitigated operationally by leaving `REVIEW_OTP` unset in production unless deliberately enabled, and by rate-limiting OTP sends to 3 per minute per IP. No code change.

**Tests:** `test/platform/review-fixes.test.ts` is new.
- Deep link `/app/some/deep/path` returns 200 with the shell.
- `/apple-touch-icon.png` returns 404.
- Deleting `bob@x.com` leaves `alice.bob@x.com`'s OTP row alone.

`npx vitest run` in `workers/api` shows 17 tests passing across 4 files, and `tsc --noEmit` is clean. The output includes "RPC receiver does not implement destroy/stats" messages. They are expected, because `LibraryDO` is still a placeholder (the route tolerates it), and they don't fail tests.

**CONTRACT ISSUES:** none new.

**Notes for the integrator**
- The `run_worker_first: true` change means every request, static assets included, passes through the worker.
- `LibraryDO` still needs `stats()` and `destroy()`.
