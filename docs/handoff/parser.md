# parser (feat/parser)

## Implementation report
Branch: `feat/parser`
Commits:
- `d485afa` feat(extractor): safeFetch, Readability extraction, sanitizer, images, package
- `2a82d75` feat(parser): queue consumer, shared cache, R2/D1 writes, markParsed RPC, DLQ

Both commits end with the requested Co-Authored-By line. I added no dependencies and did not touch `packages/shared` or `docs/api.md`.

**Implemented, packages/extractor (all in `src/`)**
- `ssrf.ts` and `safe-fetch.ts`:
  - **SSRF guard:** blocks localhost, `*.local`/`*.internal`, single-label hosts, and our own hosts passed in config. It also blocks private IPv4 ranges including CGNAT and link-local. IPv6 is covered too: loopback, ULA, link-local, mapped/compat forms, NAT64 and 6to4.
  - **safeFetch:** manual redirects (max 5), each hop re-validated. 15 s timeout also covers the body stream, 5 MB streamed cap, content-type dispatch (html/image/pdf/other).
  - **Errors and decoding:** `FetchError` carries a `transient` flag. `decodeHtml` handles charset.
- `extract.ts`: linkedom + Readability. Returns title, byline, siteName (falls back to og:site_name, then host), lang, publishedTime, excerpt, content HTML, text and og:image. Returns null for empty pages.
- `sanitize.ts`:
  - **Allowlist:** sanitize-html with absolutized URLs, best-srcset pick, lazy-load `data-src` handling, and `rel`/`target` on links.
  - **Dropped:** srcset attribute, 1x1 pixels, known tracker hosts, and anything with a javascript:/data: scheme.
  - **Embeds:** iframes become `a.embed-card` link cards.
- `images.ts`: up to 50 images, 4 at a time, converted through an injected transform (1600 px webp, thumb 400 px) and stored as `img/{sha256}.webp`. If the transform fails, the original is kept when it is a raster image of 10 MB or less; SVG is never kept. Images that fail to download are dropped from the article.
- `package.ts`: `article.html` wrapper (lang, title, no external refs), manifest per design §7.3, and `package.zip` via fflate with images stored (level 0).
- `pipeline.ts`: `buildContent()` runs HTML to `article.html`, `text.txt`, images, `thumb.webp` and `package.zip`. Word count uses `Intl.Segmenter`; reading minutes use shared `readingMinutes`. Text under 500 characters gives status `partial`.

**Implemented, workers/parser**
- **Flow:** checks the shared cache first (public jobs without `force`), then loads raw HTML or `safeFetch`es, then `buildContent`. R2 files go under `content/{id}/` or `private/{userId}/{id}/`, then the D1 `content` row (public only), then `LIBRARY.getByName(userId).markParsed(itemId, result)`.
- **Retries:** transient errors get `message.retry` with backoff of 30·2ⁿ s. After the 3rd retry (attempt 4) the job is marked `failed` directly.
- **Permanent failures:** http 4xx, `not_html`, `blocked_url`, `extract_failed`, `raw_missing` go straight to `markParsed` failed.
- **DLQ:** the `sroka-parse-dlq` branch marks items failed with `parse_failed`.
- **Bad messages:** malformed messages are acked and dropped.
- `env.ts` declares a minimal local `LIBRARY` RPC interface instead of importing the DO type.

**Not implemented**
- Browser Run fallback: left as a TODO at the extract-failed point, gated on `BROWSER_RENDER_ENABLED`.
- PDF/YouTube/oEmbed dispatch: they fail as `not_html`.
- Per-site KV rules and AMP canonical resolution.
- AMP and multi-page "next" link handling.

**Tests**
- Extractor: 79 passed, covering SSRF cases, 18 XSS vectors, redirects, size cap, timeouts, the 50-image cap, the zip manifest and stored-vs-deflated entries.
- Parser: 12 passed (11 new plus the existing smoke test), run in workerd with a stubbed `globalThis.fetch` and fake `IMAGES` and `LIBRARY`.
- Root `npm run typecheck` is clean.

**CONTRACT ISSUES**
1. The D1 `content` table has no excerpt, siteName, author, readingMinutes or leadImage columns, but `ParseResult` needs them on a cache hit. I write `meta.json` into the content dir as the last R2 write and read it back on a hit. It also serves as the cache-validity marker. A row with no `meta.json` is treated as a miss.
2. `parsed_at` is stored in epoch milliseconds, since the design only says INTEGER. Any GC or reconcile code in the API must use the same unit.
3. The parser never touches `ref_count` (inserted as 0). Whoever attaches content (the DO's `markParsed` or the API) must increment it. A cache hit on an existing content row also needs that increment.
4. The `content` table does not exist yet (no `workers/api/migrations` in this branch). My tests create it inline with the design §7.2 columns. The cache lookup and insert catch D1 errors and degrade to a miss, so the parser works before the migration lands.
5. The design asks for fetching the normalized URL. I fetch `job.url` as saved (some sites need the query params) and use the normalized URL only for the cache key.

**Notes for the integrator**
- `workers/parser/vitest.config.ts` now has `deps.optimizer.ssr.include: ["sanitize-html","postcss"]`. Without it workerd fails on postcss's `require('nanoid')` under vitest. Production builds bundle with esbuild, which worked in the research brief.
- The test `LibraryDO` placeholder has no `markParsed`; the parser tests inject a fake `LIBRARY`.
- Orphan R2 objects can remain if a job crashes after the R2 writes but before `markParsed`, because contentIds are fresh per attempt. The weekly GC should cover this.
- `leadImageKey` is only set when the Images binding produced a thumbnail. If the transform fails there is no thumb, and the API should handle a missing `leadImageKey`.

## Review
I found 4 medium and 3 low defects on `feat/parser`. Tests pass: extractor 79/79 and parser 12/12, run in a temporary worktree linked to the branch's own workspace packages.

**1. [med-high] Captured pages from non-UTF-8 sites become garbled text**
- **Where:** `workers/parser/src/process.ts:179`, with `decodeHtml` in `packages/extractor/src/safe-fetch.ts:167-178`.
- **Problem:** Captured raw HTML is decoded with `decodeHtml(await gunzip(obj.body))` and no content type, so `decodeHtml` reads the `<meta charset>` tag in the HTML. The API stores the captured HTML as UTF-8, because it arrives as a JSON string, but the page's original meta tag (for example `iso-8859-2` or `windows-1252`) is still in it. The UTF-8 bytes are then decoded with that legacy charset. I confirmed "żółć" comes out as "ĹźĂłĹÄ". Common Polish and older European sites are affected. No test covers it.
- **Fix:** For the `rawKey` path, decode as UTF-8 always: `decodeHtml(bytes, "text/html; charset=utf-8")` or `new TextDecoder().decode(bytes)`. Add a test with a fixture containing `<meta charset="iso-8859-2">`.

**2. [med] Memory can run out on image-heavy pages**
- **Where:** `packages/extractor/src/images.ts:65-66, 99, 104-106`, `pipeline.ts:74-81`, `workers/parser/src/index.ts:66`.
- **Problem:** Each image can be up to 10 MB (`maxBytes: MAX_IMAGE_BYTES`), and originals of up to 10 MB are kept when the transform fails. All 50 images stay in memory, are copied again into the zip, and are held until the R2 puts finish. Up to 5 jobs in a batch run in parallel in one isolate. If the Images binding is down, or a page has many large images, one job can use hundreds of MB, well over the 128 MB isolate limit. The whole batch then crashes on every attempt and ends up in the DLQ.
- **Fix:**
  - Add a total byte budget per article, for example 40 MB of stored images; skip images once it is reached.
  - Process batch messages one at a time (a `for` loop instead of `Promise.all`), or limit to 2.
  - Optionally lower the per-image download cap.

**3. [med] CPU limit can be exceeded**
- **Where:** `workers/parser/wrangler.jsonc` (no `limits`), together with `index.ts:66`.
- **Problem:** A queue invocation gets the default 30 s CPU limit. Five parallel Readability/linkedom parses of pages up to 5 MB, plus sanitize-html, `zipSync` and the SHA-256 hashes, can exceed it. The batch fails and is retried, then sent to the DLQ.
- **Fix:** Add `"limits": { "cpu_ms": 300000 }` and/or process messages one at a time.

**4. [med] Nobody increments `ref_count`, so the GC can delete content that is still in use**
- **Where:** `process.ts:231` (`ref_count` inserted as 0) and the cache-hit path at `process.ts:160-163`.
- **Problem:** `docs/api.md` §9 (line 306) says markParsed's "ok:false … parser may then skip ref-counting", which makes the parser responsible for ref-counting. Design §9.3 says LibraryDO does it, and LibraryDO has no D1 binding contract for that. The implementer pushed the work elsewhere (contract issue 3), so neither side does it. The weekly GC deletes R2 content where `ref_count = 0` and the content is older than 30 days, so every public article would be removed from R2 while items still reference it.
- **Fix:** Follow api.md. After `markParsed` returns `{ok:true}` for a public ok/partial result, on both a fresh parse and a cache hit, run `UPDATE content SET ref_count = ref_count + 1 WHERE id = ?1`, catching errors since the cron reconciles drift. Otherwise get an explicit ruling in `docs/decisions.md` before merge.

**5. [low] Wrong thumbnail can win**
- **Where:** `packages/extractor/src/images.ts:78-89`.
- **Problem:** The thumbnail rank check runs before `await o.transform(...)`. If both lead candidates (og:image and the first article image) are processed at once, the lower-priority one can finish last and overwrite `thumb`.
- **Fix:** Check `rank < curRank` again after the await, before assigning.

**6. [low] Embed-card links lack `rel` and `target`**
- **Where:** `packages/extractor/src/sanitize.ts:147`.
- **Problem:** Iframe-to-link-card output gets `{href, class}` only. Normal links get `rel="noopener noreferrer nofollow" target="_blank"`, but these don't, which goes against the stated rule that all links carry `rel`/`target`.
- **Fix:** Add the same `rel` and `target` attributes to embed-card links.

**7. [low] Permanent errors are retried as if transient**
- **Where:** `workers/parser/src/index.ts:29-35`, `process.ts:179`.
- **Problem:** Any exception that is not a `FetchError` is retried as transient. That includes a corrupt raw gzip (the DecompressionStream TypeError) and crashes of linkedom/Readability/fflate, all of which will fail the same way every time. Each job burns 4 attempts and about 3.5 minutes before it is marked failed. Also, when `markParsed` throws after a successful parse (line 37-42), the retry parses again with a new contentId. That duplicates the R2 objects and the D1 `content` row.
- **Fix:**
  - Map a gunzip failure to a permanent `raw_corrupt` failure.
  - Wrap `buildContent` and treat synchronous parse exceptions as permanent `extract_failed`.
  - For a failed `markParsed`, keep the result (for example in the message, or by checking R2 for the content) or accept the duplicates and leave them to GC, and document that.

Not defects, checked and fine:
- The SSRF guard handles IPv4/IPv6 literals and mapped forms, and re-validates every redirect.
- The sanitizer allowlist and the `javascript:`/`data:`/svg-onload handling are correct.
- Retry counting matches `max_retries` 3 (attempts 1 to 4).
- DLQ payload matches api.md §9.
- Private content never reads or writes the shared cache.
- R2 key layout matches §9.

## Fix report
Branch: `feat/parser` could not be checked out here because worktree `wf_2331d63d-83a-3` already has it. I worked on a detached HEAD from `feat/parser` (2a82d75) and committed **9a82ff5** (parent 2a82d75). The `feat/parser` ref has not moved. To land it, run `git merge --ff-only 9a82ff5` or `git branch -f feat/parser 9a82ff5` from a worktree that has the branch checked out. The commit is in the shared object store.

**Fixed (all 7 findings were real):**
1. Non-UTF-8 pages: the `rawKey` path now decodes with `decodeHtml(raw, "text/html; charset=utf-8")`, so the page's original `<meta charset>` is ignored. I added a parser test with `<meta charset="iso-8859-2">` and Polish text.
2. Memory:
   - `processImages` now has `MAX_TOTAL_IMAGE_BYTES` (40 MB per article, overridable with `maxTotalBytes`). Images over the budget are skipped.
   - Batch messages are processed one at a time with a `for` loop instead of `Promise.all`.
   - I did not lower the per-image 10 MB download cap.
3. CPU: `workers/parser/wrangler.jsonc` now has `"limits": {"cpu_ms": 300000}`, in addition to the sequential processing.
4. `ref_count`: a new `incrementRefCount` in `process.ts` runs `UPDATE content SET ref_count = ref_count + 1 WHERE id = ?1` after `markParsed` returns `{ok:true}`. It covers both fresh parses and cache hits. It skips private and failed results, and swallows errors because the cron reconciles drift. I added a test covering a fresh parse followed by a cache hit.
5. Thumbnail race: the rank is re-checked after `await transform`. I confirmed the test fails when the re-check is removed.
6. Embed-card links now carry `rel="noopener noreferrer nofollow"` and `target="_blank"`, with a test.
7. Permanent errors:
   - A gunzip failure now returns a permanent `raw_corrupt` failure, with a test. `FetchError("too_large")` still passes through.
   - A synchronous exception from `buildContent` now returns a permanent `extract_failed`.
   - When `markParsed` throws after a successful parse, the retry still re-parses with a new contentId. I accepted that and left the orphaned R2 objects and `content` row (`ref_count` 0) to the weekly GC. A code comment in `index.ts` documents this.

**Not fixed:** nothing skipped except the per-image cap reduction noted in item 2.

**Tests:** extractor 82/82 (was 79), parser 15/15 (was 12). Typecheck passes for both workspaces.

**CONTRACT ISSUES:** none new. The ref-counting split between parser and LibraryDO (design §9.3 versus api.md §9) is still unresolved. The parser now follows api.md §9. If the integrator makes LibraryDO ref-count instead, remove `incrementRefCount` to avoid double counting.

**Notes for the integrator:** `cpu_ms: 300000` requires a paid-plan Workers account. No dependencies were added.
