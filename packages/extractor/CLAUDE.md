# @sroka/extractor — pure extraction pipeline

fetch → Readability (linkedom DOM) → sanitize-html allowlist → image rewriting → fflate package. Runs in node (tests) and Workers (parser).
No Cloudflare bindings here: image transforms/R2 writes are injected by `workers/parser` (pass functions in).

## Commands
- `npm test -w @sroka/extractor` (node vitest, `src/**/*.test.ts`) · `npm run typecheck -w @sroka/extractor`

## Key files
- `src/ssrf.ts` (host/IP guard), `safe-fetch.ts` (safeFetch, decodeHtml), `extract.ts` (Readability), `sanitize.ts` (allowlist, absolutize, rewriteImages), `images.ts` (processImages, injected transform), `package.ts` (article.html wrapper + zip), `pipeline.ts` (`buildContent`: html -> files[]), `extractor.test.ts`.
- Image transform and R2 are injected by workers/parser; per-image failures never throw (fallback to original raster <=10 MB, else dropped).

## Decisions that apply
- D6 (safeFetch rules: http/https only, block private/loopback IP literals + localhost + own hosts, ≤5 manual redirects, 15 s timeout, 5 MB cap; Readability on linkedom; sanitize allowlist; max 50 images; package zip with manifest.json per design §7.3).
- Use `normalizeUrl`, `PARSER_VERSION`, `PackageManifest`, `readingMinutes`, `ParseResult` from `@sroka/shared`.
- Deps already installed: @mozilla/readability, linkedom, sanitize-html (+@types), fflate. Don't add deps.
