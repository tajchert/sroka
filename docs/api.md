# Sroka HTTP & sync contract (v1)

Source of truth for shapes: `packages/shared/src/*.ts` (zod). This document defines **semantics** the schemas can't express.
If this document and `docs/decisions.md` disagree, decisions.md wins; if this document and the schemas disagree on a *shape*, the schema wins — fix the doc.

Contents: 1 Conventions · 2 Hosts, auth, CORS · 3 Errors · 4 Objects · 5 Items endpoints · 6 Tags endpoints · 7 Sync · 8 Mutation semantics (applyOps) · 9 Parse pipeline interface · 10 Content delivery · 11 Imports/exports · 12 Account, me, config · 13 URL normalization · 14 Limits & rate limits · 15 Storage notes for implementers

---

## 1. Conventions

- JSON bodies, `Content-Type: application/json`, UTF-8. Keys **camelCase**. SQL is snake_case.
- Times: **epoch milliseconds** (integers) everywhere, except the `exp` segment of signed content URLs (unix seconds) and CSV `time_added` (unix seconds, Pocket-compatible).
- IDs: items, tags, jobs, content = **UUIDv7** strings (`uuidv7()` from `@sroka/shared`). User ids are Better Auth ids (opaque `[A-Za-z0-9_-]`, ≤64 chars).
- All `/v1/*` endpoints require auth except `GET /v1/config` (and the unauthenticated `GET /v1/health`).
- Validation: every request is validated with the zod schema named in each section (Hono `zValidator`-style, or `schema.safeParse`). Failures → `400 {error:"invalid_request", message, issues}`, **except** a failure whose only issue has `message:"invalid_url"` (from `HttpUrl`) → `400 {error:"invalid_url"}`. Build the body with `toApiError(zodError)` from `@sroka/shared` (api.ts).
- Query-string numbers are coerced (`z.coerce`). Unknown query/body keys are ignored (zod strips).
- Optional request header **`X-Sroka-Device: <deviceId>`** on REST mutation endpoints; used as the LWW tie-breaker. Default deviceId `"rest"` (`REST_DEVICE_ID`).

## 2. Hosts, auth, CORS

| Host | Serves | Auth | CORS |
|---|---|---|---|
| `sroka.app` (dev `http://localhost:8787`) | `/` landing, `/app/*` SPA, **and** `/api/auth/*`, `/v1/*` (same-origin for the web app) | Better Auth **cookie** (host-only) | none needed (same origin) |
| `api.sroka.app` (dev: same `localhost:8787`) | `/api/auth/*`, `/v1/*` | **`Authorization: Bearer <token>`** (cookies also accepted) | allow-list below |
| `c.sroka.app` (dev `http://127.0.0.1:8787`) | `/s/…` signed content only | signature in path; cookieless | `Access-Control-Allow-Origin`: request origin if in `[APP_ORIGIN, ...DEV_ORIGINS]` |

The API Worker picks the behaviour by `new URL(req.url).host`: equal to `new URL(CONTENT_ORIGIN).host` → content route only (everything else 404). Otherwise the normal app (`/api/auth/*`, `/v1/*`, `/app/*` SPA fallback, assets).
In dev, `localhost:8787` acts as both `sroka.app` and `api.sroka.app`.

Dev-only var `DEV_ORIGINS` (comma-separated; `.dev.vars`: `http://localhost:5173`, unset in production) lists extra web origins (vite dev server): they are added to Better Auth `trustedOrigins` and to the content-route CORS allow-list. (Through the vite proxy, `/api` and `/v1` requests are same-origin for the browser but keep `Origin: http://localhost:5173`.)

**CORS for `/api/*` and `/v1/*`** (Hono `cors`): `origin` echoed only if it equals `APP_ORIGIN` (or is in `DEV_ORIGINS`), or starts with `chrome-extension://` or `moz-extension://`; otherwise no CORS headers. `allowMethods: GET,POST,PATCH,DELETE,OPTIONS`; `allowHeaders: Content-Type, Authorization, X-Sroka-Device`; `exposeHeaders: set-auth-token, Retry-After, X-Retry-After, Content-Disposition`; `credentials: false`; `maxAge: 600`. (The MV3 service worker with host_permissions bypasses CORS anyway.)

### 2.1 Auth endpoints (Better Auth, mounted at `/api/auth/*`)

| Call | Body | Result |
|---|---|---|
| `POST /api/auth/email-otp/send-verification-otp` | `{"email":"a@b.c","type":"sign-in"}` | `200 {"success":true}` — same response whether or not the account exists. Dev (`ENVIRONMENT=development`): OTP logged as `[sroka] OTP for a@b.c: 123456`, email not sent. |
| `POST /api/auth/sign-in/email-otp` | `{"email":"a@b.c","otp":"123456"}` | `200 {token, user}`, header **`set-auth-token: <token>`**, plus session cookie. Creates the user if new. Errors below. |
| `GET /api/auth/get-session` | — | `{session, user}` or `null` |
| `POST /api/auth/sign-out` | `{}` | `200` |

**Turnstile (web only).** When `TURNSTILE_SECRET_KEY` is set, `send-verification-otp` requests from the web app (`Origin` = `APP_ORIGIN`/`DEV_ORIGINS`, or no `Origin` and host = the `APP_ORIGIN` host) must carry header **`X-Turnstile-Token: <widget token>`**; the server verifies it via Turnstile siteverify (success + hostname). Failure/missing → `400 {"code":"TURNSTILE_FAILED","message":"Verification failed. Please try again."}` (checked before the per-email throttle, so it consumes no budget). Tokens are single-use. **Exempt (tradeoff):** requests with any other `Origin` (extension `chrome-extension://…`) or without an `Origin` on `api.sroka.app` (native apps, curl) skip Turnstile, because those clients cannot run the widget; they are bounded only by the per-IP and per-email limits (§14). With `ENVIRONMENT=development` a request without `Origin` is always exempt (locally app and API share `localhost:8787`, so native debug clients would otherwise be blocked). Unset secret (local dev/self-host) = no check. The site key comes from `GET /v1/config` (`turnstileSiteKey`, §12).

Better Auth errors are **not** `ApiError`: body `{"code": "<CODE>", "message": "<text>"}`. Sign-in codes: `INVALID_OTP` (400, wrong/unknown code), `OTP_EXPIRED` (400), `TOO_MANY_ATTEMPTS` (403, code invalidated after 5 wrong tries → request a new one). Rate limiter on `/api/auth/*`: `429` with body `{"message":"Too many requests. Please try again later."}` (no `code`) and header **`X-Retry-After: <seconds>`** (not `Retry-After`).
`trustedOrigins` (cookie/origin check): `[APP_ORIGIN, API_ORIGIN, "chrome-extension://<EXT_ID>", ...DEV_ORIGINS]`.

OTP: 6 digits, expires in 300 s, 5 attempts, stored hashed. Sessions 90 days, rolling (refreshed at most daily).
Extension/native: store the `set-auth-token` value verbatim (it contains `.` and may contain `=`; don't URL-encode) and send `Authorization: Bearer <value>`.

### 2.2 `/v1` auth middleware

`auth.api.getSession({headers})` → `userId = session.user.id`. No session → `401 {"error":"unauthorized"}`. Clients: on 401 keep local data, ask the user to sign in again.

## 3. Errors

Body: `{"error": "<code>", "message"?: "<human text>", "issues"?: [{path, message}]}` (`ApiError`).

| Status | `error` | When |
|---|---|---|
| 400 | `invalid_request` | schema validation failed (`issues` present) or semantic problem (`message` e.g. `too_many_tags`, `empty_patch`, `bad_cursor`) |
| 400 | `invalid_url` | URL not http(s) / not normalizable (also: schema failure whose only issue is `invalid_url`, see §1) |
| 401 | `unauthorized` | no/invalid session |
| 403 | `forbidden` | content route: bad signature or expired (`message`: `bad_signature`/`expired`/`malformed`) |
| 404 | `not_found` | unknown or deleted item/tag/job, unknown route |
| 405 | `method_not_allowed` | content route non-GET/HEAD |
| 409 | `not_parsed` | `GET /v1/items/:id/content` while `contentId` is null |
| 410 | `resync_required` | sync pull cursor older than tombstone horizon |
| 413 | `payload_too_large` | body/html/import file above limits |
| 415 | `unsupported_media_type` | import not multipart / unknown file type |
| 429 | `rate_limited` | `/v1`: with `Retry-After: <seconds>`. (`/api/auth/*` 429s come from Better Auth: `X-Retry-After`, §2.1) |
| 500 | `internal` | unexpected; logged |

## 4. Objects

### 4.1 Item (`Item` in model.ts)

```json
{
  "id": "01929b1e-6f1c-7a2b-9c3d-4e5f60718293",
  "url": "https://example.com/post?utm_source=x",
  "canonicalUrl": "https://example.com/post",
  "title": "How magpies think",
  "excerpt": "Corvids are …",
  "siteName": "Example",
  "author": "Jane Doe",
  "lang": "en",
  "leadImageUrl": "https://c.sroka.app/s/1760486400/AbC…xyz/p/0192f3c4-…/thumb.webp",
  "leadImageKey": "thumb.webp",
  "wordCount": 2310,
  "readingMinutes": 10,
  "contentId": "0192f3c4-1111-7222-8333-444455556666",
  "contentPrivate": false,
  "parseStatus": "ok",
  "parseError": null,
  "status": "unread",
  "isFavorite": false,
  "progress": 0.42,
  "progressAnchor": 17,
  "savedAt": 1760400723120,
  "archivedAt": null,
  "lastReadAt": 1760400802000,
  "source": "extension",
  "tags": ["birds", "science"],
  "seq": 18410,
  "kind": "article",
  "fileName": null,
  "fileSize": null
}
```

- `title` on the wire = user title (set via `item.setTitle`/PATCH) if any, else parsed title, else the provisional title given at save time, else `null`. Clients fall back to `canonicalUrl`/domain for display.
- `leadImageUrl`: signed URL (section 10) of `{contentDir}/{leadImageKey}`, freshly signed in every response (24 h TTL), `null` if no thumbnail. A convenience for list views; it goes stale in stored sync rows (rows are only re-sent when their seq changes).
- `leadImageKey`: thumbnail path relative to the content dir (normally `"thumb.webp"`), or `null`. Long-lived clients (native) should download the thumbnail into their cache when they pull the row; if the URL has expired, build a fresh one as `baseUrl` from `GET /v1/items/:id/content` + `leadImageKey`.
- `parseStatus`: `pending` (queued/working) → `ok` | `partial` (content usable but poor; offer "Open original"; `parseError` = `partial_content`, or `paywalled` when a fetched/rendered page carries paywall markup — only the teaser was saved, suggest re-saving via the extension while signed in) | `failed` (`parseError` = short reason like `http_404`, `timeout`, `not_html`, `extract_failed`, `too_large`, `blocked_url`). `contentId` non-null ⇒ content readable; `parseStatus` may still be `failed` after a failed refresh (the earlier content is kept), or `pending` during a refresh.
- `progress` 0..1, `progressAnchor` = 0-based index into `article.html` body's `querySelectorAll(PROGRESS_ANCHOR_SELECTOR)` (`"p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure"`, from `@sroka/shared` limits.ts) of the first element at/below the top of the viewport, or null. Web and native count identically.
- `status` `unread|archived`; `archivedAt` set when archived, null when unread.
- `source`: `share|extension|web|import|email|api` or null.
- `tags`: names, sorted case-insensitively.
- `seq`: last change sequence (section 7).
- `kind`: `article` (default; every pre-v4 item) | `pdf` (uploaded file, §5.8). `fileName` / `fileSize` (bytes): original name and size of an uploaded PDF, else `null`. A `pdf` item has `url = {APP_ORIGIN}/pdf/{sha256hex}` (hash of the file bytes; the dedupe key), `siteName:"PDF"`, `contentPrivate:true` and a `contentId` from the moment it exists, so **it is readable while `parseStatus` is still `pending`**; clients must not wait for parsing. Parsing only fills title/author/lang/excerpt/word count; extraction problems are `parseStatus:"ok"` with `parseError` = `pdf_no_text` | `pdf_encrypted` | `pdf_extract_failed`.

### 4.2 Tag

`{"id":"0192…","name":"Machine learning","count":12,"seq":18399}` — `count` only in `GET /v1/tags`, `PATCH /v1/tags/:id` (and `TagResponse`), not in sync pull.
Tag names: NFC, trimmed, whitespace collapsed (`normalizeTagName`), 1–64 chars, **case-insensitively unique** per user, where "case-insensitive" means equal `tagKey(name)` (= `normalizeTagName(name).toLowerCase()`, full Unicode: `Żółw` = `żółw`). The stored casing is the one from the creating op (or latest rename).

### 4.3 Job

```json
{"id":"0192…","kind":"import","status":"running","format":"pocket_csv","total":5012,"done":1200,"skipped":3,
 "error":null,"createdAt":1760400723120,"updatedAt":1760400730000}
```
`status`: `queued → running → done | failed`. `done` counts processed rows (created + duplicates + skipped). `total` null until the file is parsed.

## 5. Items endpoints

All mutations are translated server-side into sync ops (`at = Date.now()`, deviceId from `X-Sroka-Device` or `"rest"`) and applied through the same `applyOps` path as `/v1/sync/push` (section 8).

### 5.1 `POST /v1/items` — quick save (web, extension)
Request `CreateItemRequest`:
```json
{"url":"https://example.com/post?utm_source=x","title":"Optional page title","tags":["birds"],"source":"extension",
 "html":"<!doctype html><html>…</html>"}
```
- `html` (optional): the rendered page as a JSON string. The extension sends the DOM minus non-JSON-LD scripts, styles, stylesheet/preload links, SVG and templates. Max `LIMITS.maxHtmlBytes` = 5 MiB of UTF-8; whole body max 6 MiB (check `Content-Length` first) → `413 payload_too_large`. Presence ⇒ captured/private content.
- The whole JSON body may be gzipped (`Content-Encoding: gzip`; the extension does this whenever `html` is present). The server detects gzip by its magic bytes (`1f 8b`), not the header, and inflates with a 6 MiB output cap → `413 payload_too_large`; a corrupt stream → `400 invalid_request` (`invalid_gzip`). The 6 MiB limit applies to both the sent and the inflated body.
- Server: new `itemId = uuidv7()`, op `item.add` (`onDuplicate:"readd"`, `source` default `"api"`). If the canonical URL already exists → the existing item is re-added (Pocket semantics, section 8.3) and returned with `created:false`.
- If `html` given: gzip it (`CompressionStream("gzip")`), `CONTENT.put("raw/{userId}/{itemId}.html.gz")` (itemId = the resulting item's id, i.e. the existing one for duplicates), enqueue `ParseJob {userId,itemId,url,rawKey,force:true,parseGen}` (store the raw HTML first, then DO `requestParse(itemId, {rawKey, force:true})` bumps `parse_gen`, sets `parse_status=pending` and returns the job; any plain job the `item.add` returned is not sent — §9).
- Without `html`: enqueue `ParseJob {userId,itemId,url,parseGen}` only if the item is new, or it is a duplicate whose `parseStatus` is `failed`.
- Response **`202 {"item": Item, "created": true|false}`** (`CreateItemResponse`). Item has `parseStatus:"pending"` when newly queued.
- Errors: 400 `invalid_url`, 400 `invalid_request`, 413.
- **Waiting for parse** (applies to 5.1, 5.6 and a `409 not_parsed` from 5.7): while `parseStatus === "pending"`, clients poll `GET /v1/items/:id` with backoff 2 s, 4 s, 8 s, … capped at 30 s, giving up after 5 min (show "still processing"). When `parseStatus` leaves `pending` and `contentId` is non-null → call `/content`. On `failed` → show `parseError` and offer Refresh / Open original. (Sync clients simply see the updated row in their next pull.)

### 5.8 `POST /v1/items/pdf` — upload a PDF
Body = the raw file bytes (`Content-Type: application/pdf`; `application/octet-stream` is tolerated, the magic bytes decide). `Content-Length` is required. Query: `name` (original file name, required; control and format (bidi/zero-width, `\p{Cf}`) characters removed, `/`, `\` and `:` replaced by `_`, trimmed, truncated to 255 UTF-16 units keeping a trailing `.pdf` and never splitting a surrogate pair; empty after cleaning → `document.pdf`), `tag` (repeatable), `source` (`ItemSource`, default `api`; web sends `web`, Android `share`).
- Errors: `411 length_required` (no/invalid `Content-Length`), `413 payload_too_large` (> 50 MiB: checked on the header before reading and again while streaming), `415 unsupported_media_type` (other content type, or no `%PDF-` within the first 1024 bytes), `400 invalid_request` (missing `name`, bad `tag`/`source`, body shorter/longer than `Content-Length`), `409 storage_full` (sum of live PDF `fileSize` + this file > 2 GiB), `401`.
- Flow: the body is streamed to R2 `private/{userId}/{contentId}/document.pdf` (`contentType application/pdf`) while its SHA-256 is computed (never buffered), then one DO call `addPdf` decides in a single transaction: (1) a live item with the same url hash exists: it is re-added like `item.add` `onDuplicate:"readd"` (tags unioned, `savedAt` bumped, back to `unread`) and returned with `created:false`; (2) quota exceeded: `storage_full`; (3) else a new item is inserted exactly like `item.add` plus `kind:"pdf"`, `fileName`, `fileSize`, `contentId`, `contentPrivate:true`, `siteName:"PDF"`, provisional title = file name without `.pdf`, `parseStatus:"pending"`, and a `ParseJob` with `pdf` is enqueued (§9; over the parse budget the sweep sends it later). Before the R2 `put` the route calls `reservePdfUpload(contentId)` (§9 R2 cleanup). The uploaded object is deleted (via `waitUntil`, so it survives a client disconnect) only on outcomes known to be pre-commit: quota/validation rejection, a failed/aborted stream, a destroyed library, or a duplicate whose existing `document.pdf` is intact (the route `HEAD`s it). If the duplicate's `document.pdf` is missing (or the duplicate is not a `pdf` item), the route calls DO `repointPdf` instead: in one transaction the existing item gets the new `contentId`/`fileName`/`fileSize`, `seq` is bumped, `parse_gen` is incremented with a new pdf `ParseJob`, the old content dir is queued for deletion and the reservation is dropped; the upload is kept and the response is `created:false`. On an unknown outcome (the `addPdf` RPC threw after possibly committing) the object is kept and the reservation sweep reclaims it if no item references it. The request body is always read to the end (a guard that rejects a non-PDF or an over-long body keeps draining and drops/clips the bytes; mid-body errors leave the runtime's request stream unread).
- `202 {"item": Item, "created": boolean}` (`CreateItemResponse`).
- `item.add` ops never create PDFs (see §8.2 step 3a); all other ops (status, favorite, tags, title, progress, delete) work unchanged on PDF items. `item.delete` removes the private content dir, i.e. the file.

### `GET /pdf/:sha256` (app host)
`/pdf/{sha256hex}` is the item URL of an uploaded PDF, made a working "open original" link: with a session (cookie or bearer) and a live PDF item of that hash: `302` to its signed `document.pdf` URL (§10); no session: `302 /app/`; unknown or malformed hash, or not owned: `404`. `Cache-Control: private, no-store`. `/pdf/*` reaches the Worker before static assets (`run_worker_first`).

### 5.2 `GET /v1/items` — list / search / lookup
Query `ListItemsQuery`: `state` (`unread`*default*|`archived`|`favorites`|`all`), `tag`, `q`, `sort` (`newest`*default*|`oldest`|`shortest`|`longest`|`archived`), `domain`, `url`, `cursor`, `limit` (1–100, default 30).

- Never returns deleted items.
- `state`: unread → `status='unread'`; archived → `status='archived'`; favorites → `isFavorite` (any status); all → everything.
- `tag`: items where the tag (matched by `tagKey`) is present. Unknown tag → empty list.
- `q`: FTS5 over title, excerpt, siteName, tags. Each whitespace-separated term is quoted and prefix-matched (`"term"*`), terms ANDed; FTS syntax characters in user input are neutralized (never 400/500 for odd input). Ordering still follows `sort`.
- `domain`: matches the item host or any subdomain; leading `www.` ignored on both sides (`displayDomain`). E.g. `domain=nytimes.com` matches `www.nytimes.com`, `cooking.nytimes.com`.
- `url`: **exact lookup** — server `normalizeUrl(url)` and matches `canonicalUrl` among live items, ignoring `state`/`tag`/`q`/`domain`. Returns 0 or 1 item, `nextCursor:null`. Invalid URL → `400 invalid_url`. (Extension badge.)
- `sort`: newest = `savedAt DESC, id DESC`; oldest = `savedAt ASC, id ASC`; shortest = `wordCount ASC NULLS LAST, id ASC`; longest = `wordCount DESC NULLS LAST, id DESC`; archived ("recently archived") = `COALESCE(archivedAt, savedAt) DESC, id DESC`.
- Paging: keyset. `nextCursor` = opaque (`encodeListCursor({k: sortValueOfLastRow, id})`), `null` when no more rows. A cursor is only valid with the same filters/sort; undecodable → `400 invalid_request` (`message:"bad_cursor"`).
- Response `200 ListItemsResponse` `{"items":[Item…],"nextCursor":"eyJrIjoxNzYwNDAw…"|null}`.

### 5.3 `GET /v1/items/:id`
`200 {"item": Item}` · `404` if unknown or deleted.

### 5.4 `PATCH /v1/items/:id`
Body `UpdateItemRequest` (≥1 field): `{"status":"archived"}`, `{"isFavorite":true}`, `{"title":"My title"}` (`""` = reset to parsed title), `{"progress":0.5,"progressAnchor":12}`, `{"tags":["a","b"]}` (**replaces** the tag set).
Mapping: status → `item.setStatus`; isFavorite → `item.setFavorite`; title → `item.setTitle`; progress/progressAnchor → `item.setProgress` (if only `progressAnchor` given, progress keeps its current value); tags → diff against current tags: `item.tag present:false` for removed names, `present:true` for added names (compare by `tagKey`).
Response `200 {"item": Item}` (after applying). `404` unknown/deleted; `400 invalid_request` (`message:"too_many_tags"` if >100). The PATCH's ops are applied **atomically** (one transaction): if any op is rejected, none is applied.

### 5.5 `DELETE /v1/items/:id`
Op `item.delete`. `204` (no body). `404` if unknown or already deleted.

### 5.6 `POST /v1/items/:id/refresh`
Op `item.refresh` (for an item of `kind:"pdf"` see §9: extraction is re-run from the stored file and the URL is never fetched; otherwise sets `parseStatus:"pending"`, bumps `parse_gen`, enqueues `ParseJob{userId,itemId,url,force:true,parseGen}`; the URL is refetched publicly — previously captured HTML is not reused). `202 {"item": Item}`. `404`.

### 5.7 `GET /v1/items/:id/content`
`200 ContentUrlsResponse`:
```json
{"articleUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/article.html",
 "baseUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/",
 "packageUrl":"https://c.sroka.app/s/1760486400/Zm9v…/p/0192f3c4-…/package.zip",
 "documentUrl":null,
 "expiresAt":1760486400000}
```
`documentUrl` is the signed `…/document.pdf` for items of `kind:"pdf"` (their `articleUrl`/`packageUrl` keep the shape but 404), `null` for articles.
Scope `p` when `contentPrivate=false`, `u.{userId}` otherwise. `409 {"error":"not_parsed"}` when `contentId` is null (pending/failed). `404` unknown/deleted.
Web reader (D7): `fetch(articleUrl)` → text → `<iframe sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox" srcdoc>` (never `allow-same-origin`) with injected, in `<head>`:
- `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src {CONTENT_ORIGIN} data:; style-src 'unsafe-inline'; script-src 'nonce-{nonce}'">` — `{CONTENT_ORIGIN}` must be explicit: the srcdoc document has an opaque origin, so `'self'` would block every image.
- `<base href="{baseUrl}" target="_blank">`, the theme `<style>`, and one `<script nonce="{nonce}">` reader script (fresh random nonce per render).
The iframe is the scroll container. Reader script ⇄ parent via `postMessage`: iframe → parent `{type:"sroka:metrics", progress, anchor}` (debounced on scroll; parent verifies `event.source`), parent → iframe `{type:"sroka:scrollToAnchor", anchor}` (restore on open). `anchor` counts `PROGRESS_ANCHOR_SELECTOR` (§4.1). Parent sends `PATCH /v1/items/:id {progress, progressAnchor}` throttled and on leave.

## 6. Tags endpoints

### 6.1 `GET /v1/tags`
`200 {"tags":[{"id":"…","name":"birds","count":12,"seq":18399}, …]}` — all live tags (including count 0), sorted by name case-insensitively. `count` = live items with the pair present.

### 6.2 `GET /v1/tags/suggestions?url=`
`200 {"recent":["birds","to-cook"],"frequent":["science"],"current":["birds"]}`
- `recent`: up to 10 distinct names ordered by the most recent `item_tags.at` with `present=1`.
- `frequent`: up to 10 names by `count` desc (ties by name), excluding names in `recent`.
- `current`: tags of the live item whose canonical URL equals `normalizeUrl(url)`; `[]` if not saved / no url / invalid url (never 400).

### 6.3 `PATCH /v1/tags/:id` `{"name":"Machine learning"}`
Op `tag.rename {from: <current name>, to: name}`. If another live tag already has that name (same `tagKey`) the tags are **merged** into the existing one (section 8.4). `200 {"tag": Tag-with-count}` (the surviving tag). `404` unknown/deleted tag.

### 6.4 `DELETE /v1/tags/:id`
Op `tag.delete {tag: <name>}`; removes the tag from all items. `204`. `404`.

## 7. Sync (native apps; any client may use it)

### 7.1 `POST /v1/sync/push`
Request (`PushRequest`): `{"deviceId":"dev_0192…","ops":[Op, …]}` — `deviceId` `^[A-Za-z0-9_.:-]{1,64}$`, ≤500 ops (more → `400 invalid_request`). Op shapes (`Op` union in ops.ts), every op has `opId` (≤64 chars, uuidv7 recommended; must be unique **per device** — idempotency is keyed on `(deviceId, opId)`) and `at` (client epoch ms):

```json
{"opId":"…a1","type":"item.add","itemId":"<uuidv7>","at":1760400723120,"url":"https://example.com/post?utm_source=x",
 "title":"Optional","tags":["travel"],"source":"share","savedAt":1760400723120,"status":"unread","isFavorite":false,"onDuplicate":"readd"}
{"opId":"…a2","type":"item.setStatus","itemId":"…","status":"archived","at":…}
{"opId":"…a3","type":"item.setFavorite","itemId":"…","value":true,"at":…}
{"opId":"…a4","type":"item.setProgress","itemId":"…","progress":0.42,"anchor":17,"at":…}
{"opId":"…a5","type":"item.tag","itemId":"…","tag":"to-cook","present":true,"at":…}
{"opId":"…a6","type":"item.setTitle","itemId":"…","title":"My title","at":…}
{"opId":"…a7","type":"tag.rename","from":"ml","to":"machine-learning","at":…}
{"opId":"…a8","type":"tag.delete","tag":"old","at":…}
{"opId":"…a9","type":"item.delete","itemId":"…","at":…}
{"opId":"…b0","type":"item.refresh","itemId":"…","at":…}
```
(`item.add` fields after `source` are optional; `savedAt/status/isFavorite` apply only when a new item is created.)

Response `200 PushResponse`:
```json
{"applied":["…a1","…a2"],"rejected":[{"opId":"…a9","reason":"unknown_item"}],
 "aliases":{"<client itemId>":"<existing itemId>"},"cursor":18423}
```
Processing rules:
1. The body is validated as `{deviceId, ops: unknown[] ≤500}`; then **each op individually** with `Op.safeParse`. An invalid op → `rejected {opId: op.opId ?? "", reason:"invalid_op"}`; the rest still apply.
2. Ops are applied **in array order**, each in its own `transactionSync`.
3. **Idempotency:** if `(deviceId, opId)` is in `applied_ops`, the op is not re-applied and is reported in `applied` (and, for an aliased `item.add`, the alias is reported again — `applied_ops` stores the alias target). REST-synthesized ops use server uuidv7 opIds under their own deviceId (`rest`/`import`), so they can't collide with client ids.
4. Applied ops (including LWW losers and no-ops) are recorded in `applied_ops(device_id, op_id, applied_at, alias)`, primary key `(device_id, op_id)`. **Rejected ops are not recorded** (a retry re-evaluates them).
5. Aliases: an `item.add` whose URL matches a different live item yields `aliases[clientId] = existingId` and stores `item_aliases(client_id → target_id)` durably. **Every** incoming `itemId` (in any later push, from any device) is first resolved through `item_aliases` (follow chains), so ops a client queued on its local id before learning the alias still apply. Clients should still rewrite pending local ops and merge the local row when they receive `aliases`.
6. Reject reasons (`RejectReason`): `invalid_op`, `unknown_item` (itemId never seen and not in `item_aliases`), `item_deleted` (item is tombstoned — delete wins), `unknown_tag` (rename/delete of a missing tag name), `invalid_url`, `too_many_tags`. Clients drop rejected ops (after reconciling via pull). An unexpected server error on a single op is reported as `invalid_op` (logged) so one bad op can't wedge a device's push. `rejected` is **not** in op order (schema-invalid ops are listed first) — match by `opId`.
8. Known order-dependence left in the spec (excluded from the convergence fuzz test): `present:false` on a tag that doesn't exist is a no-op; an `item.tag` newer than a rename/delete still depends on arrival order; two renames of the same tag — last applied wins.
7. `cursor` = `meta.seq` after the push. Clients should still pull from their previous cursor to receive the canonical rows they changed.

### 7.2 `GET /v1/sync/pull?cursor=&limit=`
Query `PullQuery`: `cursor` (int ≥0, default 0), `limit` (1–1000, default 500), `full` (optional boolean, `1`/`true`).
Response `200 PullResponse`:
```json
{"cursor":18423,"hasMore":false,
 "items":[Item…],"tags":[{"id":"…","name":"travel","seq":18399}],
 "deleted":{"items":["<itemId>"],"tags":["<tagId>"]}}
```
- Returns all item and tag rows with `seq > cursor`, ordered by `seq` ascending, at most `limit` rows **in total** (items + tags + tombstones). Live rows go into `items`/`tags`; tombstoned rows go into `deleted.items`/`deleted.tags` (ids only).
- **A page never splits a seq group** (one op stamps the rows it changes — tag rename/delete across N items, merges, `item.add` creating tags — with the same seq; an op touching more than `MAX_SEQ_GROUP` = 250 rows spreads them over consecutive seqs, so a group is bounded). After reaching `limit` rows, the server keeps adding rows until the seq changes, so a page may exceed `limit` by at most 250 rows. Implementation: select `seq > cursor ORDER BY seq LIMIT limit`, then also select all remaining rows with `seq = lastSeq`.
- `cursor` in the response = seq of the last returned row if `hasMore`, else the current `meta.seq`. Repeat until `hasMore:false`. First sync: `cursor=0`.
- Required DO test: rename a tag carried by more than `limit` items, pull with small `limit` from before the rename, and assert every item arrives exactly once.
- `410 {"error":"resync_required"}` if `0 < cursor < meta.tombstone_horizon` (the highest seq of any purged tombstone). The client then merges pending ops, pushes them, and pulls from 0.
- Clients doing a pass from 0 send `full=1` on every page of that pass; with `full` the horizon check is skipped. A pass from 0 is complete by construction because purged tombstones are only for rows the client never had or that a full pass doesn't need.
- Item rows include signed `leadImageUrl` (24 h) and the stable `leadImageKey` (§4.1); clients needing content call `GET /v1/items/:id/content`.

### 7.3 seq rules (for the DO implementer)
- `meta.seq` starts at 0. **Each op that changes anything increments `meta.seq` once** and stamps every row it changed (item, tag) with that value — except that every 250 rows (`MAX_SEQ_GROUP`) a large op takes the next seq (bounded pull groups, §7.2; the op is still one transaction). LWW losers/no-ops don't increment.
- An `item_tags` pair change bumps the **item's** seq (its `tags` array changed). Creating a tag bumps the tag's seq too.
- Tag rename bumps the tag and every live item carrying it. Tag delete tombstones the tag and bumps every item that carried it.
- `markParsed`, `item.refresh`, import batches bump the affected item(s) like any change.
- Tombstones (`deleted_at` set) keep their row with the new seq; purged after 180 days by the DO alarm, raising `meta.tombstone_horizon` to the max purged seq.

## 8. Mutation semantics (`applyOps`, LibraryDO)

`at` is first clamped: `at = clampAt(op.at, now)` (≤ now + 5 min). Stamp = `{at, dev: deviceId}`.

### 8.1 LWW
Per-field clocks in `items.clock` JSON (`ItemClock`): `title`, `status`, `isFavorite`, `progress` (progress + anchor + lastReadAt together). Incoming stamp wins iff `at > cur.at`, or `at == cur.at && dev > cur.dev` (string compare), or equal stamp (later-applied wins) — `applyLww()`. Losing ops are **applied** (no change, no seq bump).
`item_tags` pairs: same LWW rule with the stamp `{at, dev}` stored in `item_tags.at` / `item_tags.dev` — use `pairWins(incoming, {at, dev})` from `@sroka/shared` (lww.ts).

### 8.2 `item.add`
1. `canonical = normalizeUrl(url)` (fail → reject `invalid_url`), `hash = urlHash(canonical)`.
2. If `itemId` exists: tombstoned → reject `item_deleted`; live → treat as duplicate of itself (step 4 without alias).
3. Else if a live item `Y` has `url_hash = hash` → duplicate of `Y`, alias `itemId → Y.id` (step 4).
4. Duplicate handling: `onDuplicate:"readd"` (default): `savedAt=max(savedAt, at)` **always** (order-independent, even if the status stamp loses); with stamp on `status`: if it wins → `status=unread`, `archivedAt=null`; union `tags` (each as `item.tag present:true` with the op stamp); provisional `title` only if the item has no title. `onDuplicate:"merge"`: only union tags. (Re-queue parsing per 5.1.)
5. Else insert a new live item: `id=itemId`, `url`, `canonical_url`, `url_hash`, `title` = provisional title or null, `status = op.status ?? "unread"`, `archivedAt = status==archived ? at : null`, `isFavorite = op.isFavorite ?? false`, `savedAt = op.savedAt ?? at`, `source = op.source ?? null`, `parse_status="pending"`, `clock` = `{status}` stamped, plus `isFavorite` **only if the op sets `isFavorite`** (stamping the default `false` would make the result depend on which duplicate add created the row); `title` NOT stamped — the provisional title can be replaced by the parser), tags added, FTS row inserted. The caller (REST handler / push handler) enqueues a `ParseJob` for every newly created item (push: `ParseJob{userId,itemId,url,parseGen}`; up to 100 per `sendBatch`). `applyOps` returns these jobs to the caller (internal RPC result `{response: PushResponse, parseJobs: ParseJob[]}`), with `parse_gen` already incremented.
   3a. The URL space `${APP_ORIGIN}/pdf/{64 lowercase hex}` (host = the `APP_ORIGIN` host, path matching `^/pdf/[0-9a-f]{64}$`) is reserved for uploaded PDFs (§5.8): if no live item has this `url_hash`, the op is rejected `invalid_url` (REST: `400 invalid_url`; imports count it as skipped). With a live item (the pdf) it is an ordinary duplicate re-add.
6. A URL whose only matching item is tombstoned creates a **new** item (re-save after delete).

### 8.3 Other item ops (target must be live; unknown → `unknown_item`, tombstoned → `item_deleted`)
- `item.setStatus`: LWW `status`; archived → `archivedAt = at`; unread → `archivedAt = null`.
- `item.setFavorite`: LWW `isFavorite`.
- `item.setProgress`: LWW `progress`; sets `progress`, `progressAnchor = anchor ?? null`, `lastReadAt = at`.
- `item.setTitle`: LWW `title`; stores the **user title** (`""` → null = fall back to parsed/provisional). Parser never overwrites a user title.
- `item.tag`: resolve the tag per 8.4 (renames/tombstones), else find the live tag by `name_key = tagKey(tag)`. Missing + `present:true` → create tag (`id=uuidv7()`, name as given, `name_key`). Missing + `present:false` → applied no-op. Pair LWW (8.1). Adding beyond 100 present tags → `too_many_tags`.
- `item.delete`: tombstone (`deleted_at = at`), delete FTS row; item_tags rows kept (not returned). Unknown → `unknown_item`; already deleted → applied no-op. **Delete wins**: all later ops on it are rejected `item_deleted`.
- `item.refresh`: `parse_status=pending`, `parse_error=null`, `parse_gen += 1`; caller enqueues `ParseJob{…, force:true, parseGen}` (returned in `parseJobs`).

### 8.4 Tag ops
All tag lookups use `name_key = tagKey(name)` (never SQLite `NOCASE`, which folds ASCII only).
- `tag.rename {from,to}`: `from` missing → `unknown_tag`. Same tag (equal `tagKey`) → change casing. `to` names another live tag → **merge**: every pair of `from` is LWW-merged onto `to` **keeping its own `{at, dev}` stamp** (using the rename's stamp would make the result depend on op arrival order), then `from` is tombstoned. Otherwise rename in place. No LWW on tag names (last applied wins).
  Every rename (in place or merge) records `tag_renames(from_key, to_tag_id, at)` (upsert on `from_key`).
- `tag.delete {tag}`: missing → `unknown_tag`. Tombstone the tag, set all its pairs `present=0`; pairs whose stamp loses to the op take the op stamp, newer pair stamps are kept.
- **Stale tag ops:** a `tag.rename` / `tag.delete` whose `at` is older than the matched live tag's `created_at` is an **applied no-op** (it was issued before that tag existed — e.g. an offline device's delete must not destroy a tag created later under the same name). Keeps the outcome independent of arrival order.
- **Stale offline `item.tag` ops** (a device that hadn't seen the rename/delete):
  1. Rename: if `tag_renames` has `from_key = tagKey(op.tag)` with `rename.at >= op.at`, the op targets `to_tag_id` instead (follow chains, max 10 hops; if the final target is tombstoned, apply rule 2 to it). An op with `at` later than the rename uses the name as given (may create a new tag with the old name).
  2. Delete: if no live tag has that key but a tombstoned one does with `deleted_at >= op.at`, a `present:true` op is an **applied no-op** (doesn't resurrect the tag). Ops with `at > deleted_at` create a new tag (new id).

### 8.5 FTS
`CREATE VIRTUAL TABLE items_fts USING fts5(title, excerpt, site_name, tags)` — a **regular** FTS5 table (it stores its own copy; overrides design §7.1 `content=''`, which can't be updated and needs original values to delete). Rowid = `items.fts_rowid` (INTEGER, unique). Maintained manually in the same `transactionSync`: add → `INSERT (rowid, …)`; title/parse/tag changes → `UPDATE items_fts SET … WHERE rowid=?` (or delete+insert); item delete → `DELETE FROM items_fts WHERE rowid=?`. `tags` column = present tag names joined with spaces; tag rename/delete updates every affected item's row.

## 9. Parse pipeline interface (api ↔ parser)

- Queue `sroka-parse` message = `ParseJob` (parse.ts): `{userId, itemId, url, rawKey?, force?, pdf?: {contentId}, parseGen}`. Producer: `env.PARSE_QUEUE.send(job)` / `sendBatch`.
- **Generations:** the DO increments `items.parse_gen` on every enqueue (new `item.add`, failed-duplicate re-add, html save, `item.refresh`) and sets `parse_status=pending`; jobs come from the DO (`applyOps` → `parseJobs`, or DO RPC `requestParse(itemId, {rawKey?, force?}) → ParseJob | null` used by the html save path). `markParsed` returns `{ok:false}` and changes nothing when `result.parseGen !== items.parse_gen` (a newer job is in flight or finished) **or the item is no longer `pending`** (a result for this gen was already applied: duplicate delivery, or a DLQ `failed` after a committed success). The alarm sweep re-sends stuck `pending` jobs **with the same gen** (it does not bump `parse_gen`, so a still-queued original stays valid). The parser calls DO RPC `parseWanted(itemId, parseGen) → boolean` before fetching and again before writing R2, and drops the job when it is false.
- **Parse budget (per user):** jobs returned by `applyOps` / `requestParse` pass a DO token bucket (1000 burst, refilled 1000/hour). Over-budget jobs are not returned; their items stay `pending` (marked for the sweep, `parse_requested_at = 0`) and the DO alarm sends them within the budget every ~10 min. `item.refresh` on an item already `pending` for < 10 min is an applied no-op (no new job).
- **PDF jobs (decisions D12):** a job with `pdf` belongs to an uploaded PDF whose original is already at `private/{userId}/{pdf.contentId}/document.pdf`; the parser only extracts metadata/text from it and never fetches `url`. Jobs come from the upload (§5.8), `item.refresh` (`{…, force:true, pdf}`; an applied no-op for a pdf item without content id; the 10-minute refresh coalescing applies) and the stale-pending sweep, which re-derives `pdf` from `kind` + `content_id`. `markParsed` for a pdf item: ok/partial are accepted only with `contentId === items.content_id` and `contentPrivate:true` (else `{ok:false}`), update metadata (a parsed title replaces the stored one only when non-null; a user title still wins) and never delete the content dir (same content id = no content change); a `failed` result records only `parse_status`/`parse_error`, so the item stays readable.
- **R2 cleanup:** `item.delete` deletes the item's captured HTML (`parse_raw_key`) and its private content dir; a parse request without the stored raw key (refresh) deletes the raw capture; `markParsed` deletes the item's previous private content dir when the content changes. The parser deletes the private dir it wrote when `markParsed` returns `ok:false` (article jobs only; for PDF jobs it never deletes anything, since all jobs of an item share the dir with `document.pdf` and the same `text.txt` key). **PDF upload reservations (DO schema v5):** the upload route calls `reservePdfUpload(contentId)` before the R2 `put`, inserting `pdf_uploads(content_id PRIMARY KEY, at)`; `addPdf` (created) and `repointPdf` delete the row in their transaction. The DO alarm (`sweepPdfUploads`) deletes `private/{userId}/{contentId}/` for reservations older than 1 hour whose `content_id` no live item references, then the row (rows of referenced ids are just dropped; a failed R2 delete keeps the row for the next alarm). This reclaims uploads orphaned by a client disconnect, a failed delete or an unknown commit outcome. A destroyed library (account deletion) is tombstoned: every RPC refuses to recreate it (`markParsed`/`parseWanted` → false), and the parser's weekly cron deletes `private/`, `raw/`, `uploads/` prefixes of user ids no longer in D1.
- **Content references / GC (shared `content/{id}/`, decisions D6):**
  - Invariant: content referenced by a live item (`content_id = id AND content_private = 0 AND deleted_at IS NULL`) is never deleted. A `failed` re-parse keeps the old content referenced; tombstoned items reference nothing (no undelete exists; re-saving a URL creates a new item, which attaches again).
  - LibraryDO marks content ids dirty in DO table `content_ref_outbox(content_id, gen)` inside the transaction that changes a reference (`markParsed` ok/partial: old public id + new public id; `item.delete`: the item's public id). A flush (after `applyOps`/`markParsed`, from the alarm, serialized per instance) recomputes "live?" from `items` and writes D1 `content_refs` (`INSERT … ON CONFLICT DO NOTHING` / `DELETE`) plus `content.last_used_at = max(…, now)` and `ref_count = COUNT(content_refs)` (cache only) in one D1 batch, then deletes outbox entries whose `gen` didn't change meanwhile. A failed flush leaves the outbox and moves the alarm to +10 min. At-least-once and idempotent.
  - `destroy()` deletes `content_refs` of the user (best effort); the GC also drops refs of user ids no longer in D1.
  - Backfill RPC `reemitContentRefs() → {refs, pending}` marks every live public reference dirty and flushes (`pending > 0` = flush failed).
  - Parser weekly cron (`src/gc.ts`): (1) backfill — once `gc_state.gc_backfill = 'start'`, calls `reemitContentRefs` for D1 `user` ids in id order (cursor `gc_backfill_cursor`, 1000 users/run, stops at a user whose flush fails) and sets `gc_backfill_done = '1'` at the end; (2) GC — no-op until `gc_backfill_done`; drops dead-user refs; marks up to 200 rows `gc_at = now` with one statement re-checking "no `content_refs` and `last_used_at` < now − 30 days" (rows already marked by an interrupted run are resumed first); for each marked row re-checks refs (referenced → unmark, keep), deletes the R2 prefix `content/{id}/` (paged) then the row; soft cap 20 000 R2 objects/run; logs one `gc summary` line.
- `rawKey` = `raw/{userId}/{itemId}.html.gz` (gzip of the captured HTML). Present ⇒ parse that HTML (base URL = `url`), result is **private** (`contentPrivate:true`, R2 `private/{userId}/{contentId}/…`), never written to or read from the shared D1 cache.
- No `rawKey` and no `force` ⇒ parser may reuse D1 `content` row with same `url_hash` + `PARSER_VERSION`, `status = ok`, `cacheable = 1`, `gc_at IS NULL`, `parsed_at` within 7 days; the lookup is one `UPDATE … SET last_used_at = now … RETURNING id` (touch atomic with the lookup, see GC below). Every public parse inserts its `content` row **before** writing R2 (row insert failure = transient error, retried); only canonical `ok` parses get `cacheable = 1`. The shared cache is only read **and written** when the fetched URL equals its canonical form up to fragment/credentials (`sharesCacheKey`): a URL with tracking params or a different query order is fetched and stored uncached (its page may reflect those params). `partial` parses are never written to the shared cache.
- Result → RPC on the user's DO: `env.LIBRARY.getByName(userId).markParsed(itemId, result: ParseResult) → Promise<{ok: boolean}>`. `ok:false` when the item is unknown or deleted, or the result is stale (`parseGen` mismatch). The parser does not count references (see "Content references / GC" below). `ParseResult` fields: `status ok|partial|failed`, `parseGen` (echo of the job), `contentId` (required for ok/partial, absent for failed — enforced by the schema), `contentPrivate`, `title, excerpt, siteName, author, lang, wordCount, readingMinutes` (nullable), `leadImageKey?` (path relative to the content dir, normally `"thumb.webp"`), `error?`, `parserVersion`.
- `markParsed` with `ok`/`partial` sets `content_id`, `content_private`, `lead_image_key`, metadata (parsed `title` only replaces the stored non-user title when non-null), `parse_status`, `parse_error = error ?? null`, bumps seq, updates FTS.
- A `failed` result updates **only** `parse_status`, `parse_error` and seq — never `content_id`, `content_private`, `lead_image_key` or metadata (an earlier content stays readable; its `contentPrivate` is unchanged).
- DLQ consumer (`sroka-parse-dlq`) calls `markParsed(itemId, {status:"failed", parseGen: job.parseGen, contentPrivate:false, title:null, excerpt:null, siteName:null, author:null, lang:null, wordCount:null, readingMinutes:null, error:"parse_failed", parserVersion: PARSER_VERSION})`.
- R2 layout per content dir (`r2Keys.contentDir`): `article.html`, `text.txt`, `img/{sha256}.webp`, `thumb.webp`, `package.zip` (manifest.json + article.html + img/*; `PackageManifest`).
- **Site rules (decisions D10):** KV `CONFIG` key `site-rules:v1:{host}` (host lowercase, no `www.`), JSON `SiteRuleSchema` (`@sroka/shared` `site-rules.ts`). Lookup per job: full host, then parent domains (`ruleLookupHosts`); the most specific valid rule wins; invalid JSON/schema → ignored + `site_rule_invalid` warn; per-isolate cache 60 s (misses cached too); KV errors = no rule. Applied before the shared-cache lookup: `disabled` → `failed` `site_disabled` (no fetch). For every parse (captures too): `removeSelectors` removed before extraction, `contentSelector` used instead of Readability when it matches ≥ 40 chars of text, `minTextChars` = `partial` and render threshold (default 500). Fetch only (not captures): `stripParams` removed from the fetched URL (cache key unchanged), `userAgent: "browser"` sends a desktop Chrome UA (`BROWSER_UA`) for the page fetch and the render, `render`/`waitForSelector` (below). Rule edits take effect within 60 s but don't invalidate the 7-day shared cache (refresh = `force`).
- **Browser Run fallback (decisions D10, parser `src/render.ts`):** never for captured HTML (`rawKey`). After the plain fetch + extraction, a render is wanted when: the fetch got 403/429/503 (bot wall), the 2xx page is a bot challenge (Cloudflare `Just a moment…`/`/cdn-cgi/challenge-platform/`, Akamai `Access Denied`+edgesuite, Incapsula, DataDome, PerimeterX: `detectBotWall`), nothing was extractable, the text is < `minTextChars` (a JS-only shell asking to "enable JavaScript" counts here), or the rule says `render: "always"`. Not done when `BROWSER_RENDER_ENABLED != "true"`, there is no `BROWSER` binding, or `render: "never"` (`fallbackOutcome = disabled`). Budgets: one unit of the per-user (`BROWSER_RENDER_DAILY_PER_USER`, 30) and the global (`BROWSER_RENDER_DAILY_GLOBAL`, 500) daily counter (UTC day) in D1 `render_budget` (atomic conditional upsert; D1 error = over budget); over budget → `fallbackOutcome = budget`, `error_detail = render_budget`, plain result kept / failure as before. Call: `env.BROWSER.quickAction("content", {url, rejectResourceTypes: ["image","media","font"], gotoOptions: {waitUntil: "networkidle2", timeout: 25 s}, waitForSelector?: {selector, timeout: 10 s}, userAgent?, bestAttempt: true})`, overall 30 s cap; the binding returns a `Response` with `{success, result: html, meta: {status, title, finalUrl}}` (errors `{success:false, errors[]}` 4xx/5xx). `meta.finalUrl` must pass the SSRF guard (else `blocked_url`). The rendered HTML goes through the same extract → sanitize → images → package path (images are still fetched by `safeFetch`). Result choice: render text ≥ `minTextChars` → `ok` via render; shorter → `partial`, the longer of plain/render is kept; render error/challenge/empty → `fallbackOutcome = failed` with `error_detail` (`render_http_<n>`, `render_timeout`, `render_error`, `render_bot_wall`, `render_extract_failed`) and the plain result (or the original failure: `http_403`, `bot_wall`, `extract_failed`; transient 429/503 are retried — each delivery may render again, within budget). A rendered `ok` canonical parse is cacheable like any other. **Paywall detection** (`@sroka/shared` `detectPaywall`, never for captures): JSON-LD `isAccessibleForFree: false`, `<meta article:content_tier=locked>`, or Medium's `Member-only story` banner in the page the text came from → result `partial` with `error = paywalled` (not cacheable); a short paywalled teaser does not trigger a render (it would stay a teaser).
- **Short captures (`rawKey`):** when the captured HTML extracts to nothing or to < `minTextChars`, the parser also does one plain fetch of the URL (site-rule `stripParams`/`userAgent` apply, no render). It keeps whichever text is longer; the result stays private and uncached. `method` = `fetch` when the fetched text wins, else `capture`; `fallback_outcome` = `ok`/`partial` (by fetched text length) or `failed` with `error_detail` `fetch_<code>` / `fetch_extract_failed`. A fetched page that wins is checked for paywall markup.
- **Parse attempts (decisions D10):** after each finished job (final outcome of a delivery, incl. cache hits and `site_disabled`; transient retries are not recorded) and each DLQ failure the parser writes one D1 `parse_attempts` row (§15), one `parse` log line and one Analytics Engine `parse` point (docs/observability.md). Insert errors are logged, never fatal. `method`: `fetch` | `render` (rendered HTML used) | `capture` | `cache` | `api` (site JSON API, X / Twitter posts; decisions D11). `fallback_outcome`: `none` | `ok` | `partial` | `failed` | `budget` | `disabled`. `http_status`: plain fetch status (or the rendered page's status when its HTML was used). The weekly cron deletes rows older than 30 days and expired `render_budget` rows.

## 10. Content delivery (signed URLs, D7)

URL: `{CONTENT_ORIGIN}/s/{exp}/{sig}/{scope}/{contentId}/{file}`
- `exp` unix seconds; default `defaultExp()` = now + 24 h rounded **up** to the hour.
- `scope` = `p` (R2 `content/{contentId}/`) or `u.{userId}` (R2 `private/{userId}/{contentId}/`).
- `sig` = base64url (no padding, 43 chars) of HMAC-SHA256(`CONTENT_URL_SIGNING_KEY`, `"{exp}/{scope}/{contentId}"`). Covers the directory, so relative `img/…` in article.html work.
- `file`: 1–4 segments of `[A-Za-z0-9_-][A-Za-z0-9._-]*` (no `..`), e.g. `article.html`, `img/ab12….webp`, `package.zip`, `thumb.webp`.
- `exp` must be canonical (`^[1-9]\d{0,11}$`, no leading zeros) and `sig` exactly 43 canonical base64url chars, so each signature maps to one URL (stable CDN cache keys).
- Build with `buildContentUrls` / `buildContentUrl`; verify with `verifyContentPath(secret, pathname)` → `{ok, r2Key, isPrivate, …}`. Pass `new URL(req.url).pathname` **unmodified**; never `decodeURIComponent` it first (`%2F` would become a separator and enable traversal — encoded forms are rejected as malformed).

Route (content host only): `GET`/`HEAD` only (else `405`). Malformed → `403 forbidden message:malformed`; bad signature → `403 bad_signature`; expired → `403 expired`; R2 miss → `404`. Success headers:
- `Content-Type` by extension: `.html` `text/html; charset=utf-8`, `.txt` `text/plain; charset=utf-8`, `.webp` `image/webp`, `.zip` `application/zip`, `.json` `application/json`, `.pdf` `application/pdf`, else R2 `httpMetadata.contentType` or `application/octet-stream`.
- `.pdf` additionally: `Content-Type: application/pdf`, `Content-Disposition: inline; filename="document.pdf"`, and the CSP is `default-src 'none'; object-src 'none'; frame-ancestors 'none'` instead of the HTML CSP (no `sandbox`, which would stop Chrome's built-in PDF viewer when the signed URL is opened directly: "Open in new tab", `/pdf/:sha256`). **Needs a Chrome check**; if Chrome still refuses to render, loosen only as far as needed and update this line (the content host has no cookies and serves the file inert under `nosniff`). The web reader does not depend on it (blob URL).
- `Access-Control-Allow-Origin`: the request `Origin` if it equals `APP_ORIGIN` or is in `DEV_ORIGINS`, else omitted; always `Vary: Origin`. `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; sandbox`.
- Public: `Cache-Control: public, max-age=86400, immutable`. Private: `Cache-Control: private, no-store`.
- `ETag` from R2; honour `If-None-Match` (304) where cheap. `Content-Length` set.

## 11. Imports & exports

### 11.1 `POST /v1/imports` (multipart/form-data)
Fields: `file` (File, ≤20 MiB → else 413), `format` = `pocket_csv | pocket_html | instapaper_csv | netscape_html`. Not multipart → 415.
Response **`202 {"job": Job}`**; poll `GET /v1/imports/:id` → `200 {"job": Job}` (404 if not the caller's job) until `done`/`failed`.
Limits: 10 imports per day per user (429 `rate_limited`, jobs that failed with `workflow_unavailable` don't count); empty file → 400; bad `format` → 400.
Server: stores the upload at `uploads/{userId}/{jobId}.{csv|html|zip}`, inserts the D1 `jobs` row (`kind:"import"`, `queued`), then starts a **Cloudflare Workflow** (`IMPORT_WORKFLOW`, `ImportWorkflow`, instance id = job id). If the workflow cannot start the job is marked `failed` (`error:"workflow_unavailable"`), the upload deleted and the route returns 503. Workflow steps:
1. `parse` — job → `running`; parse the upload (own tolerant scanners; zip: ≤20 entries, ≤40 MiB per entry / 50 MiB total, else `zip_too_large`; >50 000 rows → `too_many_rows`), sort newest first, pre-assign `itemId`s and write batches of 200 rows to R2 (`uploads/{userId}/{jobId}/rows-{n}.json`; step output is limited to 1 MiB). Sets `total` (valid + invalid rows) and `skipped`/`done` = invalid rows (no usable http(s) URL).
2. `apply-N` (per batch, retried) — `applyOps` with deviceId `"import"`, `item.add` ops (`opId = "{jobId}:{row}"` so retries replay idempotently; `source:"import"`, `onDuplicate:"merge"`, `savedAt`, `status`, `isFavorite`, `tags`), then enqueue the returned ParseJobs (newest first). If the job row no longer exists (account deleted) the step does nothing and the workflow ends. `progress-N` writes absolute `done`/`skipped`; `step.sleep("3 seconds")` throttles between batches (≈12 min for 50 000 rows).
3. `finish` — job → `done`; delete the upload and row chunks. On any failure (`missing_url_column`, `no_csv_in_zip`, `bad_zip`, `zip_too_large`, `too_many_rows`, `upload_missing`, unexpected error) the job becomes `failed` with `error` set and the upload/chunks are deleted too.
Account deletion terminates the user's queued/running import workflows before wiping data.
Formats:
- `pocket_csv`: header `title,url,time_added,tags,status` (`time_added` unix s, `tags` `|`-separated, `status` `unread`|`archive`). A `.zip` containing one or more such CSVs (Pocket's 2025 export) is also accepted for this format (detect by `PK\x03\x04` magic; unzip with fflate).
- `pocket_html`: `ril_export.html` — `<h1>Unread</h1><ul><li><a href="URL" time_added="SECS" tags="a,b">Title</a>` … `<h1>Read Archive</h1>` → archived.
- `instapaper_csv`: header `URL,Title,Selection,Folder,Timestamp[,Tags]`; Folder `Unread` → unread, `Archive` → archived, `Starred` → favorite (unread), any other folder → unread + tag = folder name; `Tags` (if present) is a JSON array string.
- `netscape_html`: `<DT><A HREF="URL" ADD_DATE="SECS" TAGS="a,b">Title</A>` → unread; folder (`<H3>`) names are ignored.

### 11.2 `GET /v1/exports?format=csv|json`
Direct download (no job in this build). All live items, newest first, streamed one LibraryDO page (`exportPage`, 500 rows, unsigned) per pull. `Content-Disposition: attachment; filename="sroka-export-YYYY-MM-DD.{csv|json}"`.
- `csv` (`text/csv; charset=utf-8`): header `title,url,time_added,tags,status,favorite` (Pocket-compatible + favorite): `time_added` unix seconds, `tags` joined with `|` (a lone tag containing a comma gets a trailing `|`; `|` inside a tag name becomes `/`), `status` `unread|archive`, `favorite` `0|1`. RFC 4180 quoting. Anti formula-injection: `title` and `tags` cells starting with `= + - @ TAB CR` are prefixed with `'` (the `pocket_csv` importer strips that `'`).
- `json` (`application/json`): `ExportJson` `{"format":"sroka-export","version":1,"exportedAt":…, "items":[ExportItem…]}`.

## 12. Account, me, config

- `GET /v1/me` → `200 MeResponse` `{"user":{"id","email","name","emailVerified","createdAt"},"stats":{"unread":12,"archived":340,"favorites":8,"tags":21},"isAdmin":false}`. `isAdmin` is true when the user's email is in env `ADMIN_EMAILS` (comma-separated, case-insensitive); the web app shows the hidden `/app/admin` page only then.
- `DELETE /v1/account` body `{"confirm":"DELETE"}` (else 400) → `200 {"deleted":true}`. Server: DO `destroy()` (`ctx.storage.deleteAll()`), delete R2 prefixes `private/{userId}/`, `raw/{userId}/`, `uploads/{userId}/` (list+delete, may continue in `waitUntil`), D1 `jobs` rows, Better Auth user (sessions, accounts, verifications). Shared `content/` is left for GC. Client then signs out locally.
- `GET /v1/config` (**no auth**) → `200 ConfigResponse` = KV `CONFIG` key `"config"` (JSON) merged over defaults, plus `appOrigin` = `env.APP_ORIGIN` (never from KV) and optional `turnstileSiteKey` = `env.TURNSTILE_SITE_KEY` (public; absent when unset, web then renders no widget) (the extension opens `${appOrigin}/app/` for "Open library"):
  `{"appOrigin":"https://sroka.app","turnstileSiteKey":"0x4AAAAAAFXEWydv4XHizEV8","minVersions":{"android":null,"ios":null,"extension":null},"features":{"imports":true,"exports":true,"browserRender":false,"highlights":false,"realtime":false},"limits":{"maxOpsPerPush":500,"maxHtmlBytes":5242880,"maxImportBytes":20971520}}`. `Cache-Control: public, max-age=300`.
- `GET /v1/health` (no auth) → `200 {"ok":true}`.
- `POST /v1/client-errors` (**no auth**, web client error reporting) body `ClientErrorRequest` `{"message","stack"?,"url"?,"userAgent"?,"release"?}` (`message` required; strings are truncated: message 1000, stack 4096, url/userAgent 300, release 64; body ≤ 16 KiB else `413`) → `204`. Logged server-side at error level with `event:"client_error"`; nothing is stored. Best-effort rate limit 10/min per IP per isolate → `429 {"error":"rate_limited"}` + `Retry-After`. Invalid body → `400`.
- Every `/v1` response carries `x-request-id` (the `cf-ray`); an unhandled server error answers `500 {"error":"internal","requestId":"<cf-ray>"}` — quote the id when reporting a problem (see `docs/observability.md`).

## 13. URL normalization (`normalizeUrl`)

1. Only `http:`/`https:` → else `invalid_url`. Input trimmed.
2. Scheme + host lowercased (WHATWG URL; IDN → punycode); trailing dot on host removed.
3. Default ports dropped (`:80` http, `:443` https).
4. Userinfo removed. Fragment removed.
5. Tracking params removed (name case-insensitive): `utm_*`, `fbclid`, `gclid`, `dclid`, `gbraid`, `wbraid`, `msclkid`, `mc_eid`, `mc_cid`, `igshid`, `ref_src`, `_hsenc`, `_hsmktg`, `yclid`.
6. Remaining params sorted by name (stable for repeated names); empty query removed; re-serialized with `URLSearchParams` (space → `+`).
7. Path kept as-is — **trailing slashes are not stripped** (`/a` ≠ `/a/`); empty path → `/`.
8. `www.` is kept; `http` is not upgraded.
`url_hash = sha256_hex(canonical)`. Example: `HTTPS://Example.COM:443/Path?utm_source=x&b=2&a=1#top` → `https://example.com/Path?a=1&b=2`.

## 14. Limits & rate limits

| Limit | Value |
|---|---|
| ops per push | 500 |
| pull page | default 500, max 1000 |
| list page | default 30, max 100 |
| URL length | 4096 |
| title length | 1000 |
| tag name | 1–64 chars; ≤100 tags per item |
| search `q` | ≤200 chars |
| `html` in save | 5 MiB (body 6 MiB) |
| import file | 20 MiB, 50 000 rows |
| PDF upload | 50 MiB per file; 2 GiB total `fileSize` of live PDF items per user; file name 255 chars |
| clock skew clamp | now + 5 min |
| tombstone retention | 180 days |
| applied_ops retention | 30 days |
| signed URL TTL | 24 h (rounded up to the hour) |

Rate limits (clients must handle `429` with backoff: `Retry-After` on `/v1`, `X-Retry-After` on `/api/auth/*`): Better Auth global 100 req/min/IP (`storage:"database"`), `send-verification-otp` 3/min per IP (custom rule), Better Auth's built-in `/sign-in/*` rule 3 per 10 s per IP. Per email (any IP, `src/auth-throttle.ts`, D1 `auth_throttle`): OTP sends 5 / 15 min and 20 / day; failed code checks 10 / 15 min and 30 / day, after which even a correct code gets `429` until the window ends. `POST /v1/imports` 10/day is reserved atomically (conditional insert). Parse jobs per user: §9 parse budget. Tombstone retention counts from server time (`tombstoned_at`), not the client `at`. `/v1` per-user soft limits (MAY be enforced via DO counters): `POST /v1/items` 120/min, `POST /v1/sync/push` 60/min, `POST /v1/imports` 10/day.

## 15. Storage notes for implementers

- **LibraryDO** schema = design §7.1 plus:
  - `items.user_title TEXT` (user override; wire `title = user_title ?? title`), `items.domain TEXT` (host without `www.`, for the `domain` filter), `items.fts_rowid INTEGER UNIQUE` (FTS key, §8.5), `items.lead_image_key TEXT`, `items.parse_gen INTEGER NOT NULL DEFAULT 0` (§9).
  - `tags.name_key TEXT NOT NULL` (= `tagKey(name)`), `CREATE UNIQUE INDEX … ON tags(name_key) WHERE deleted_at IS NULL`; no `COLLATE NOCASE` anywhere for tags.
  - `item_tags.dev TEXT NOT NULL` (pair stamp = `{at, dev}`, §8.1); index on `(tag_id)`.
  - `applied_ops(device_id TEXT, op_id TEXT, applied_at INTEGER, alias TEXT, PRIMARY KEY(device_id, op_id))`, pruned after 30 days.
  - `item_aliases(client_id TEXT PRIMARY KEY, target_id TEXT NOT NULL)` — never pruned (one small row per duplicate add); deleted with the library.
  - `tag_renames(from_key TEXT PRIMARY KEY, to_tag_id TEXT NOT NULL, at INTEGER NOT NULL)` — purged with tombstones (180 days).
  - `items_fts` regular FTS5 (§8.5). `meta` keys `seq`, `tombstone_horizon`. Migrations: append-only steps, version in a one-row `_schema(id=1, version)` table (DO SQLite rejects `PRAGMA user_version` with SQLITE_AUTH). Schema v2 adds `items.tombstoned_at`, `tags.tombstoned_at`, `tag_renames.recorded_at` (server time; used for 180-day purging — `deleted_at` stays the client stamp for LWW/stale-op checks) and `items.parse_requested_at`, `items.parse_raw_key` (stale-pending sweep). Schema v4 adds `items.kind TEXT NOT NULL DEFAULT 'article'`, `items.file_name`, `items.file_size` (+ partial index `items_pdf`). Schema v5 adds `pdf_uploads(content_id TEXT PRIMARY KEY, at INTEGER NOT NULL)` (upload reservations, §9). Schema v3 adds `content_ref_outbox(content_id TEXT PRIMARY KEY, gen INTEGER NOT NULL)` and index `items_content` (§9 "Content references / GC").
- **D1** `jobs` = design §7.2 plus `format TEXT`, `skipped INTEGER NOT NULL DEFAULT 0`. `content` = design §7.2 plus `cacheable INTEGER NOT NULL DEFAULT 1`, `last_used_at INTEGER NOT NULL` (ms; GC grace start), `gc_at INTEGER` (GC in progress); `ref_count` is a cache of COUNT(`content_refs`). `content_refs(content_id, user_id, at, PRIMARY KEY(content_id, user_id))` (index on `user_id`), `gc_state(k PRIMARY KEY, v)` (migration 0002). Migration 0003: `parse_attempts(id PK (UUIDv7), created_at ms, user_hash (sha256(userId) hex prefix 16), item_id, domain, url (canonical; NULL for captured/private), status, error_code, error_detail (≤300), method, fallback_outcome, http_status, text_chars, word_count, images, duration_ms, render_ms, attempt, parser_version, rule_applied 0/1)` with indexes `(created_at)`, `(domain, created_at)`, `(status, created_at)`; `render_budget(key PK, count, expires_at)` (index `expires_at`; keys `u:{userHash}:{utcDay}`, `g:{utcDay}`), same fixed-window pattern as `auth_throttle`.
- DO public RPC surface used by others: `applyOps(deviceId, ops: Op[]) → {response: PushResponse, parseJobs: ParseJob[]}`, `requestParse(itemId, {rawKey?, force?}) → ParseJob | null`, `pull(cursor, limit) → {ok:true, data: PullResponse} | {ok:false, error:"resync_required"}` (wrapped so the 410 case crosses RPC without throwing; lead image URLs signed in the DO with env secrets), `markParsed(itemId, ParseResult) → {ok}`, `addPdf(deviceId, {itemId,url,title,fileName,fileSize,contentId,tags,source,at}) → {ok:true,item,created,parseJobs} | {ok:false,error}` (PDF upload commit, §5.8), `reservePdfUpload(contentId)`, `repointPdf(deviceId, {itemId, expectContentId, contentId, fileName, fileSize}) → {ok:true,item,parseJobs} | {ok:false}`, `destroy()` (deletes the alarm, then `deleteAll()`, then the user's D1 `content_refs`). Maintenance RPCs: `reemitContentRefs() → {refs, pending}` (GC backfill, §9), `scheduleParseSweep()` (called by the API when a queue send fails 3×; moves the alarm ~31 min out) and `sweepStalePending(now?)` (the alarm re-enqueues items `pending` > 30 min with a bumped `parseGen`, reusing the saved raw key). List/get/tags/suggestions/`stats()` (for `/v1/me`)/export helpers are internal to `workers/api`.

## 16. Admin (D10)

All `/v1/admin/*` routes require a session **and** an email listed in env `ADMIN_EMAILS`; anyone else gets `404 {"error":"not_found"}` (unauthenticated: `401`). Schemas: `Admin*` in `@sroka/shared`. Data: D1 `parse_attempts` (30-day retention), KV `CONFIG` keys `site-rules:v1:{host}`.

- `GET /v1/admin/parse/summary?days=7` (`days` 1..30, default 7; else `400`) → `AdminSummaryResponse`: `{days, since, totals, daily:[{day:"YYYY-MM-DD" (UTC), total, ok, partial, failed}], domains:[{domain, total, ok, partial, failed, renderTried, renderOk, renderBudgetBlocked, lastAttemptAt, topErrors:[{code,count}≤3]}]}`. `renderTried` = `fallback_outcome` in ok/partial/failed, `renderOk` = `fallback_outcome=ok`, `renderBudgetBlocked` = `budget`. Domains sorted by failures then total, max 500.
- `GET /v1/admin/parse/attempts?domain=&status=&method=&fallback=&cursor=&limit=` (`limit` 1..100, default 50; `status` ok|partial|failed; `method` fetch|render|capture|cache|api; `fallback` none|ok|partial|failed|budget|disabled) → `{attempts:[AdminAttempt], nextCursor|null}`, newest first, keyset on `(created_at, id)`. `AdminAttempt`: `{id, createdAt, domain, url|null (captured/private), itemId, status, errorCode, errorDetail, method, fallbackOutcome, httpStatus, textChars, wordCount, images, durationMs, renderMs, attempt, parserVersion, ruleApplied}`.
- `GET /v1/admin/site-rules` → `{rules:[{host, rule}]}` (sorted by host).
- `GET /v1/admin/site-rules/:host` → `{host, rule}` or `404`. `PUT` body `SiteRule` (strict; `400` with zod issues otherwise) → `{host, rule}`; host is normalized with `ruleHost` (lowercase, no `www.`), `updatedAt` is set by the server. `DELETE` → `204`.
