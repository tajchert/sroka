# extension (feat/extension)

## Implementation report
**Branch:** `feat/extension`
**Commit:** `14bfd34` feat(extension): MV3 popup, background save/badge/retry queue, options, icons. It touches only `apps/extension/**`.

**Implemented**
- **API client** (`lib/api.ts`):
  - It reads the server URL from storage and sends the bearer token, plus `X-Sroka-Device` with a per-install id.
  - A 401 marks the user signed out and keeps the queue and email.
  - It handles `Retry-After` and `X-Retry-After`, and the sign-in flow reads `set-auth-token` and stores it verbatim.
- **Saving** (`lib/save.ts`):
  - Capture goes through `scripting.executeScript` and is capped at 5 MB. On restricted pages or over the cap it falls back to a URL-only save.
  - A 413 retries without `html`. Offline, 429, 5xx and 401 all queue the save. Permanent 4xx errors are not queued.
- **Retry queue** (`lib/queue.ts`):
  - It lives in `storage.local` and retries via `chrome.alarms` with backoff of 30 s doubling up to 1 h.
  - A 401 stops processing and keeps every entry. Entries are released after sign-in.
  - Queued `html` over 1 MB is dropped so the server fetches the page instead.
  - Entries are dropped after 50 failed attempts.
- **Badge** (`lib/badge.ts`, `lib/badge-cache.ts`):
  - Lookup is `GET /v1/items?url=`, and the cache is keyed by `normalizeUrl` in `storage.session`. TTL is 30 min for saved URLs and 5 min for unsaved ones.
  - It refreshes on tab activation and update. A saved page shows "✓" in teal.
- **Background**:
  - Context menus "Save link to Sroka" and "Save page to Sroka" are created in `onInstalled`.
  - The `save-page` command saves without opening the popup.
  - The alarm and `onStartup` both process the queue.
- **Popup** (360 px, black/white with an iridescent teal accent, serif headings):
  - Signed out, it shows email then a 6-digit code.
  - Signed in, it saves the current tab on open and shows "Saved ✓" or "Already saved ✓".
  - It shows the title, tag chips and suggestions, and saves tag changes with `PATCH`.
  - Archive/Unarchive, Remove and "Open Sroka" are there. "Open Sroka" opens `${appOrigin}/app/item/:id`, with `appOrigin` from `/v1/config`.
  - It also shows queued, failed and removed states.
- **Options**:
  - Server URL: it requests the origin permission and refuses to save if that is denied. A server change signs the user out and keeps the queue.
  - The capture toggle, account email and sign-out are there.
- **Manifest and icons**: permissions are activeTab, contextMenus, storage, scripting, alarms and tabs. Icons are 16/32/48/128 PNG magpie marks. They were generated once with the existing transitive `sharp` through `scripts/make-icons.mjs`, and the PNGs are committed.

**Not implemented / limits**
- Not loaded in a real Chrome. There was no manual check of the popup, shortcuts, context menus or the sign-in flow.
- No UI tests for the popup or options page.
- The popup tag input does not offer autocomplete while you type. It only shows suggestion chips.
- Pressing Enter in the tag input saves a tag. Typing a comma also saves the tag so far, so tag names cannot contain a comma.

**Tests**
- 21 vitest tests pass: api client, retry queue and save fallback, badge cache and refresh, with a mocked `chrome`.
- `npm run typecheck -w @sroka/extension` is clean.
- `npm run build -w @sroka/extension` and `npm run zip -w @sroka/extension` both succeed. The zip is `.output/srokaextension-0.1.0-chrome.zip`, 143 KB.

**CONTRACT ISSUES**
- None blocking.
- `GET /v1/me` is typed locally as `{user:{email}}`, because I did not import `MeResponse`.
- The extension signs out when `GET /v1/items?url=` returns 401, but it has no way to know whether a token was revoked or just expired.

**Notes for the integrator**
- There is no `@types/chrome` in the repo, so `apps/extension/env.d.ts` declares `chrome` as `typeof import("wxt/browser").browser`. The `lib/*` code uses `globalThis.chrome`.
- Chrome only allows one command per key. So `_execute_action` (opens the popup and saves) is on Alt+Shift+S, and the background `save-page` command is on Alt+Shift+A. The brief said Alt+Shift+S for both.
- The manifest has `tabs` for tab URLs, and `optional_host_permissions` as decided in D8 (`https://*/*`, `http://localhost/*`). `activeTab` is enough for capture.
- The server must keep `/api/auth/email-otp/send-verification-otp` and `/api/auth/sign-in/email-otp` reachable with `Origin: chrome-extension://...`. The extension id must be added to `trustedOrigins`, or the dev wildcard used.
- The `.output` and `.wxt` directories are generated and were not committed.
- No dependencies were added.

## Review
Review of `feat/extension` (commit `14bfd34`). I found eight real defects. None is a security issue and none breaks the API contract in docs/api.md. The serious ones can lose queued saves or leave the popup stuck on "Saving…". I read the code with `git show` and did not build it, run the tests or load it in Chrome.

1. **[med] Storage quota failure loses the save and leaves the popup stuck.** `apps/extension/lib/save.ts:43-45`, `lib/queue.ts:49-52`, `entrypoints/background.ts:61-64`.
   - **Problem:** `enqueue()` is called inside the `catch` of `saveWithFallback`, and nothing catches errors from it. The manifest has no `unlimitedStorage`, so `chrome.storage.local` is capped at 10 MB. A queued `html` can be up to 1 MB, and that check counts characters, so multi-byte text can be about 3 MB. A handful of offline captured saves fill the quota, and then `storage.local.set` rejects.
   - **Effect:** `saveWithFallback` throws even though it is documented as "Never throws". The background `saveTab(...).then(...)` has no `.catch`, so `sendResponse` is never called and the popup stays on "Saving…". The save is not queued, so it is lost. `processQueue` hits the same quota error in `writeQueue`, which fails the whole run.
   - **Fix:**
     - In `enqueue`, catch the quota error and retry without `html`.
     - Measure size in bytes with `new TextEncoder().encode(...).length`, and cap the total queued `html` (for example at 4 MB, or add `unlimitedStorage`).
     - Wrap `enqueue` in try/catch in `saveWithFallback`.
     - Add `.catch(e => sendResponse({ok:false, queued:false, reason:"error", message:String(e)}))` to every `onMessage` handler.

2. **[med] Queued saves are silently dropped after 50 failed attempts.** `apps/extension/lib/queue.ts:7` and `:87`.
   - **Problem:** Offline failures (status 0) increment `attempts`. With backoff capped at 1 h, 50 attempts take about 2 days. A machine left offline that long, but awake so alarms fire, loses every queued save with no notice. This goes against the spec's "never drop queued saves". Separately, any non-retryable error at `:84` (for example a 400) also deletes the entry silently.
   - **Fix:** Don't count network failures (status 0) toward the limit, or remove the cap and keep entries hourly. If an entry ever has to be dropped, record it in a `failedSaves` list that the popup can show.

3. **[med] Pages with a title over 1000 characters can't be saved.** `apps/extension/lib/save.ts:62`.
   - **Problem:** `CreateItemRequest.title` is `Title`, which is `z.string().trim().max(1000)` (`packages/shared/src/ops.ts:21`). The extension sends `tab.title` as-is. Some pages, such as SPAs and spam pages, have longer titles. The server answers `400 invalid_request`, so the save is neither stored nor queued, and queued copies are dropped.
   - **Fix:** Send `title: tab.title?.trim().slice(0, LIMITS.maxTitleLength) || undefined`. Treat any 400 other than `invalid_url` as "retry without title" rather than a permanent failure.

4. **[med] The popup rewrites the queue outside the background's lock.** `apps/extension/entrypoints/popup/App.tsx:60`, `lib/queue.ts:22-28` and `:95-99`.
   - **Problem:** `releaseQueue()` runs in the popup's JS context. The `locked()` chain only serialises calls inside one context. If the background enqueues a save or runs `processQueue` between the popup's read and write, the popup writes back an old copy of the queue. A new entry can be lost, or an entry already sent can come back and be sent twice.
   - **Fix:** Add a `{type:"release-queue"}` message that the background handles by calling `releaseQueue().then(processQueue)`. The popup should not touch the queue directly.

5. **[low] The retry alarm keeps firing every 30 s while signed out.** `apps/extension/lib/queue.ts:71` and `:41`.
   - **Problem:** On a 401 the loop stops, but the entries keep a `nextAt` in the past, so `scheduleAlarm` sets the alarm 30 s ahead every time. With an expired or revoked token that is still stored, each run sends a request that gets 401. Combined with the badge lookups, this keeps hitting the API indefinitely.
   - **Fix:** At the start of `processQueue`, return early when `getSettings().signedOut` is true and clear the alarm. Let the sign-in path (`releaseQueue` and then `processQueue`) start it again.

6. **[low] Badge cache is not cleared on sign-in or a 401.** `apps/extension/lib/api.ts:120`, `lib/settings.ts:38`.
   - **Problem:** If someone signs in to a different account from the popup, the "✓" cached for the old account stays for up to 30 minutes. Only the options page calls `clearCache`.
   - **Fix:** Call `clearCache()` in `signIn()` and `clearSession()`, and when a 401 marks the user signed out.

7. **[low] The badge can disappear after navigation (not checked in Chrome).** `apps/extension/entrypoints/background.ts:50-52`.
   - **Problem:** The badge is painted only on `status === "loading"` or a URL change. Chrome resets per-tab action values on cross-document navigation, and the asynchronous cached lookup can finish before that reset. A lookup for the previous URL can also finish late and paint the wrong state.
   - **Fix:** Also refresh on `change.status === "complete"`. Before painting, check that `(await chrome.tabs.get(tabId)).url` still matches the URL that was looked up.

8. **[low] Signing in from the popup saves the page twice.** `apps/extension/entrypoints/popup/App.tsx:41` and `:58-63`.
   - **Problem:** When a save returns `signed_out`, it has already been queued. After sign-in, `onSignedIn` releases and processes the queue and also calls `save(tab)` again, without waiting for the queue. The same URL is POSTed twice. With capture on, that means two raw HTML uploads and two forced parse jobs.
   - **Fix:** After sign-in, rely on the queue for that URL. Alternatively, remove the queued entry for `tab.url` before calling `save(tab)` again.

The rest of what I checked matches the spec and docs/api.md: the API client, bearer/`set-auth-token` handling, `Retry-After`/`X-Retry-After`, the 413 fallback, the manifest permissions and optional hosts per D8, the "Open Sroka" URL, and the Better Auth error codes. Moving the background quick-save command to Alt+Shift+A is a justified change from the brief. The missing UI tests and the lack of a real Chrome load are already listed as limits in the implementer's report.

## Fix report
**Branch:** `feat/extension-review-fixes`, created from `feat/extension` (14bfd34). `feat/extension` is checked out in another worktree (`wf_2331d63d-83a-5`), so I couldn't switch to it. The integrator should merge or cherry-pick this branch onto it.

**Commit:** `bd2aa8b fix(extension): review fixes (...)`, with the Co-Authored-By line.

**Fixed (all 8 findings; I verified each by reading the code, not in Chrome):**
1. **Storage quota.**
   - `enqueue` now measures size in bytes, caps each entry's `html` at 1 MB and the queue's total `html` at 4 MB.
   - If `storage.local.set` rejects, `writeQueue` retries without `html`.
   - `saveWithFallback` wraps `enqueue` in try/catch.
   - Every `onMessage` handler now has an error path that calls `sendResponse`, so the popup can't stick on "Saving…".
2. **Silent drops.** I removed the 50-attempt cap, so queued entries keep retrying hourly. A permanent rejection (any 400 that retrying can't help) is now recorded in `chrome.storage.local["failedSaves"]`, kept to the last 50. `readFailed()` is exported but the popup doesn't display the list yet.
3. **Long titles.** The title is trimmed and capped to `LIMITS.maxTitleLength` before sending. Any 400 other than `invalid_url` retries without the title, both on direct save and in the queue.
4. **Popup queue lock.** The popup no longer touches the queue. A new `release-queue` message (optional `skipUrl`) makes the background run `removeQueuedUrl`, then `releaseQueue`, then `processQueue`.
5. **Alarm while signed out.** `processQueue` returns early and clears the alarm when signed out. `scheduleAlarm` also skips scheduling when signed out.
6. **Badge cache.** `clearCache()` is now called in `signIn`, `clearSession`, and both 401 paths in `api.ts`.
7. **Badge after navigation.** The badge also refreshes on `status === "complete"`. Before painting, it checks the tab's current URL still matches the looked-up URL.
8. **Double save on sign-in.** `onSignedIn` sends `release-queue` with `skipUrl: tab.url`, which removes the queued copy of the current page before the popup saves it directly.

**Skipped:** nothing.

**Tests:**
- `npm test` in `apps/extension`: 27 passed.
- `wxt prepare && tsc --noEmit` typecheck: clean.
- `npm run build -w @sroka/extension`: OK.
- I did not run `npm run zip`.
- New vitest cases cover: quota fallback, the byte-based total `html` cap, a network failure never being dropped over 60 retries, `failedSaves` being recorded, the 400 retry without title, the signed-out `processQueue` no-op, and `removeQueuedUrl`.
- Not covered by tests: the badge URL-match check, the `onMessage` error paths and the popup flow.

**CONTRACT ISSUES:** none. I didn't change `packages/shared` or `docs/api.md`, and added no dependencies.

**Notes for the integrator:**
- `lib/settings.ts` now imports `lib/badge-cache.ts`. I saw no cycle problems.
- `lib/badge.ts` uses `ext().tabs?.get`. The test chrome mock has no `tabs`, so the URL check is a no-op in unit tests.
- The `Msg` union gained `release-queue`.
