# web (feat/web)

## Implementation report
Branch: `feat/web` (worktree `/Users/mtajchert/coding/priv/sroka/.claude/worktrees/wf_2331d63d-83a-4`)
Commit: `9373a09` feat(web): landing page and SPA (library, reader, tags, settings). It ends with the Co-Authored-By line you specified.

**Implemented** (all under `apps/web/`)
- **Landing (`/`)**: hero with a reader mock and an animated teal-to-violet wing sheen. It also has the Pocket pitch band, a features list, and an "Open Sroka" CTA to `/app/`. The "Get the Chrome extension" link is a placeholder pointing at `#extension`. Light and dark follow the system setting. Fonts are Literata and Schibsted Grotesk from a Google Fonts `<link>`, since `@fontsource` isn't installed.
- **Sign-in**: email, then 6-digit code, with auto-submit on the sixth digit. It handles `INVALID_OTP`, `OTP_EXPIRED`, `TOO_MANY_ATTEMPTS`, and 429 with `X-Retry-After` (shown as a countdown). The session check is `GET /v1/me`. Any 401 sends the app back to the sign-in screen.
- **Library**:
  - Sidebar with My List, Archive, Favorites, All, and tags with counts.
  - Item rows show thumbnail, title, domain (click to filter), reading time, tags, and a pending spinner or failed/partial badge.
  - Search with debounce, sort, domain filter, and infinite scroll by cursor.
  - Per-item archive, favorite, edit tags, and delete. Delete hides the item and shows an Undo toast; the real `DELETE` fires after 6 seconds.
  - "Save" box with an optimistic insert, which handles duplicates.
  - Pending items are polled per §5.1: 2s, 4s, 8s, capped at 30s, giving up after 5 minutes.
  - Keyboard: j/k, Enter, a, f, /.
- **Reader (`/item/:id`)**:
  - The header has title, site, author, reading time, Open original, archive, favorite, tags editor, Refresh, and Delete.
  - The article is fetched from the signed URL and shown in a sandboxed `srcdoc` iframe without `allow-same-origin`. It gets a CSP meta with nonce, `<base href>`, theme CSS, and the postMessage script.
  - Progress is saved by debounced PATCH (3s throttle, flushed when leaving). Scroll position is restored from the anchor on open.
  - Reader settings (theme, font, size, line height, width) are saved in localStorage and pushed to the iframe by postMessage, so changing them doesn't reload the page or lose your place.
  - Pending, failed, and partial parses each have a state with Open original and Retry.
- **Tags page**: rename (a duplicate name merges), delete with confirm, and a link to each tag's items.
- **Settings**: account email, sign out, import (format select, upload, progress polling), export links, extension link, and delete account with a typed `DELETE`.
- **Typed API client**: `src/lib/api.ts`.

**Not implemented**
- Unsaved deletes are lost if the tab closes during the 6-second undo window.
- No component or UI tests, and I haven't run the app in a browser. Only the build and unit tests were checked.
- The extension link is a placeholder.
- j/k and other shortcuts don't work while focus is inside the reader iframe.

**Tests and build**
- Typecheck is clean. Vitest passes 22 of 22: the API client, the reader srcdoc builder and settings, and the cache helpers.
- `npm run build -w @sroka/web` succeeds and produces `dist/index.html` and `dist/app/index.html`.
- I added no dependencies.

**CONTRACT ISSUES**
- `GET /v1/exports` is linked as a plain `<a download>`. It works only if the cookie is sent on a navigation, which it should be since it's same-origin.
- decisions D3 says the SPA uses `base: "/app/"`, but the existing Vite config uses the default base. Built assets therefore live at `/assets/...`, not under `/app/`. The Worker must serve `/assets/*` statically, which the current `run_worker_first` allows. If you want a base of `/app/`, change `vite.config.ts`.
- `ItemSort`, `ItemState`, `Item`, and the other shared types all worked without changes.

**Notes for the integrator**
- The article iframe's CSP forbids web fonts, so the reader uses system font stacks only.
- The article fetch needs the content host's CORS to allow the app origin. In dev, set `DEV_ORIGINS=http://localhost:5173`.
- The reader accepts `article.html` as a full document or a fragment, and adds a doctype if it's missing.
- Vite handles the `/app` deep-link fallback in dev. In production the Worker must fall back to `/app/index.html` on a 404 under `/app/*`.

## Review
I found 9 defects on `feat/web` (commit `9373a09`): none high, 4 medium, 5 low. Vitest passes 22 of 22 in the worktree; I didn't run the build or a browser. I found no security problems in the sandboxed `srcdoc`. The CSP, nonce, missing `allow-same-origin`, `<base>` escaping and postMessage source checks all match D7 and §5.7.

**Medium**

1. **Previous user's data can show after a session expires** (`apps/web/src/components/Shell.tsx:48`, `apps/web/src/routes/SignIn.tsx:49`).
   - **Problem:** a 401 only runs `qc.setQueryData(["me"], null)`, and a successful sign-in only invalidates `["me"]`. The cached `["items",…]`, `["item",id]`, `["tags"]`, `["content",…]` and `["article",…]` survive. On a shared browser, a second user signing in on the same tab sees the first user's library and articles. With `staleTime: 15s` that data is served from cache before any refetch, and the article cache never expires.
   - **Fix:** in the unauthorized handler, do `qc.clear(); qc.setQueryData(["me"], null)`. Also call `qc.clear()` (or remove every query except `me`) before invalidating after `verifyOtp` succeeds.

2. **Reopening an article restores an old scroll position** (`apps/web/src/routes/Reader.tsx:80` and `:50`).
   - **Problem:** the result of the progress PATCH is thrown away (`.catch(() => undefined)`), so `["item", id]` and the list caches keep the old `progressAnchor`. On reopen, `useQuery` returns the cached item at once, and `startAnchor` is set from that stale value once and never updated. The reader jumps to the previous session's position, and the list's "% read" is stale.
   - **Fix:** run `api.updateItem(...).then((it) => patchItem(qc, it))`. Also set `startAnchor` only from fresh data, e.g. `refetchOnMount: "always"` and gate on `!itemQ.isFetching`, or use `itemQ.dataUpdatedAt`.

3. **Reading progress is lost when the tab closes** (`apps/web/src/routes/Reader.tsx:96-103`).
   - **Problem:** progress is only flushed by the 3s timer or on React unmount. Closing the tab, reloading or navigating away drops up to 3s of progress. §5.7 and D7 say to PATCH "on leave".
   - **Fix:** add `pagehide` and `visibilitychange` (hidden) listeners that call `flush()`. Send it with `fetch(..., {keepalive: true})`, since `sendBeacon` can't do PATCH.

4. **Tag pages crash for tags containing `%`** (`apps/web/src/routes/Library.tsx:27`).
   - **Problem:** `decodeURIComponent(name)` decodes a second time. react-router 7.18 `useParams` already returns decoded values (`decodePath`, then `%2F` back to `/`).
     - A tag such as `100%` gives the param `100%`, and `decodeURIComponent` throws `URIError`, so the route crashes.
     - A tag spelled literally `a%20b` filters on `a b` instead.
   - **Fix:** `const tag = name || undefined;`.

**Low**

5. **"Still processing" message never shows** (`apps/web/src/lib/hooks.ts:147-177`).
   - **Problem:** `useParsePolling` returns `gaveUp.current`, which is a ref, so setting it never re-renders. The §5.1 message after 5 minutes never appears in the Reader. The 5-minute check also only runs when a tick fires.
   - **Fix:** use `useState` for `gaveUp` and call `setGaveUp(true)`.

6. **Enter on a focused button also opens an item** (`apps/web/src/routes/Library.tsx:89,100`).
   - **Problem:** `isTyping` excludes only inputs, textareas and selects. Pressing Enter on a focused button or link, such as Archive or Delete on a row, does that action and also runs `navigate('/item/'+items[sel].id)`, which can be a different item.
   - **Fix:** for the Enter case, ignore events whose target is a `BUTTON` or `A`, or anything matching `closest("button,a")`.

7. **Deletes still fire after sign-out** (`apps/web/src/lib/hooks.ts:71-83`).
   - **Problem:** the 6-second delete timer is module-level and survives sign-out or a 401. It fires against the next session, and if a different user signs in within 6s, against that user. In practice the item id won't exist (404 is swallowed), so this is a stray request, not data loss.
   - **Fix:** keep pending delete timers in a set. On sign-out, either flush them before calling `signOut` or cancel them.

8. **Import status polling never stops on error** (`apps/web/src/routes/Settings.tsx:37-40`).
   - **Problem:** `refetchInterval` keeps polling `GET /v1/imports/:id` every 1.5s forever if the query errors (404 or network), because `data` stays undefined.
   - **Fix:** return `false` when `q.state.status === "error"`, and show an error.

9. **Asset base path doesn't match D3** (`apps/web/vite.config.ts`).
   - **Problem:** D3 says `base: "/app/"`, but the config uses the default base, so the SPA's assets are emitted at `/assets/*`. It works with D8's `run_worker_first` (`/assets/*` is served directly from assets), but it differs from the decision. The landing and SPA chunks share `/assets`, which is fine.
   - **Fix:** either set `base: "/"` explicitly with a comment and record the change in `docs/decisions.md`, or have the integrator confirm that the Worker never intercepts `/assets/*`. No change is needed if `/assets` stays outside `run_worker_first`.

## Fix report
Branch: `worktree-wf_2331d63d-83a-12`, because `feat/web` is checked out in another worktree and I couldn't check it out. I fast-forwarded this branch to `feat/web` (9373a09) first. The new commit is `08dd67c` ("fix(web): review fixes..."), a direct child of 9373a09. Merge or cherry-pick it into `feat/web`.

**Fixed (all 9)**
1. Stale data after session change: the 401 handler now cancels pending deletes, runs `qc.clear()` and sets `["me"]` to null. `SignIn` runs `qc.clear()` after `verifyOtp` succeeds.
2. Stale scroll restore: the progress PATCH result now goes through `patchItem`. The item query uses `refetchOnMount: "always"`, and `startAnchor` is only set once `!isFetching`.
3. Progress lost on close: `pagehide` and `visibilitychange` (hidden) listeners send the pending progress with `fetch(..., {keepalive: true})`.
4. Tag param: `const tag = name || undefined`.
5. "Still processing" message: `gaveUp` is now `useState`.
6. Enter on a button or link: the Enter shortcut is skipped when the target matches `closest("button,a")`.
7. Deletes after sign-out: pending deletes are tracked in a set. Sign-out flushes them before `signOut`. A 401 or account deletion cancels them and unhides the items.
8. Import polling: `refetchInterval` returns false when the query is in error, and Settings shows an error line.
9. Asset base: I kept the default and made it explicit with `base: "/"` and a comment in `vite.config.ts`. I did not edit `docs/decisions.md`, which is outside my files.

**Tests**
- Typecheck passes.
- Vitest passes 22 of 22.
- `npm run build -w @sroka/web` succeeds and emits `dist/index.html` and `dist/app/index.html`.
- I added no new tests. The fixes are in React components and hooks, and the existing tests only cover the API client and the srcdoc builder. I ran no browser check.

**Skipped:** nothing.

**Known leftover:** `startAnchor` is never reset when `:id` changes without a remount. This was already there and I did not touch it.

**CONTRACT ISSUES:** none.

**Notes for the integrator**
- No dependencies were added.
- Assets are emitted at `/assets/*`, not under `/app/` as D3 says. This is fine only if `/assets/*` stays out of `run_worker_first`. Please record this in `docs/decisions.md`, or switch to `base: "/app/"` and fix the landing page's asset paths.
- The keepalive PATCH on leave goes straight to `fetch` at `/v1/items/:id`, so it bypasses the API client's 401 handling.
