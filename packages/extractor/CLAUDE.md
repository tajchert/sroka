# @sroka/extractor — pure extraction pipeline

fetch → Readability (linkedom DOM) → sanitize-html allowlist → image rewriting → fflate package. Runs in node (tests) and Workers (parser).
No Cloudflare bindings here: image transforms/R2 writes are injected by `workers/parser` (pass functions in).

## Commands
- `npm test -w @sroka/extractor` (node vitest, `src/**/*.test.ts`) · `npm run typecheck -w @sroka/extractor`

## Key files
- `src/ssrf.ts` (host/IP guard), `safe-fetch.ts` (safeFetch, decodeHtml), `extract.ts` (Readability; `ExtractOptions` removeSelectors/contentSelector/minTextChars from site rules), `bot-wall.ts` (`detectBotWall`, `BOT_WALL_STATUSES`), `reddit.ts` (`extractReddit`: post + comment tree as post cards, from the extension-embedded thread JSON `script#sroka-reddit-json` else shreddit markup, tried before Readability; decisions D13), `hackernews.ts` (`hnItemId`, `extractHackerNews`: HN story + comments from Algolia/Firebase APIs, async, called by the parser before fetching; D13), `discussion.ts` (shared thread model + `renderThread` post-card renderer for Reddit/HN), `twitter.ts` (`tweetRef`, `extractTweet`: X/Twitter post or thread from FxTwitter API v2, fallback X embed JSON, rendered as an article; async, called by the parser before fetching; decisions D11), `sanitize.ts` (allowlist, absolutize, rewriteImages), `images.ts` (processImages, injected transform), `package.ts` (article.html wrapper + zip), `pipeline.ts` (`buildContent`: html or pre-`extracted` article -> files[]), `extractor.test.ts`, `rules.test.ts`.
- Image transform and R2 are injected by workers/parser; per-image failures never throw (fallback to original raster <=10 MB, else dropped).

## Decisions that apply
- D11 (X/Twitter via JSON APIs), D13 (Reddit threads with comments).
- D6 (safeFetch rules: http/https only, block private/loopback IP literals + localhost + own hosts, ≤5 manual redirects, 15 s timeout, 5 MB cap; Readability on linkedom; sanitize allowlist; max 50 images; package zip with manifest.json per design §7.3).
- Use `normalizeUrl`, `PARSER_VERSION`, `PackageManifest`, `readingMinutes`, `ParseResult` from `@sroka/shared`.
- Deps already installed: @mozilla/readability, linkedom, sanitize-html (+@types), fflate. Don't add deps.
