# Sroka article extraction on Workers: research brief (2026-10-14)

Verified items were tested in a throwaway project at `/private/tmp/claude-501/sroka-research/extract/`. That project ran under `wrangler dev` with `nodejs_compat` and compat date 2026-10-01. Anything marked UNVERIFIED comes from docs only or was not tested.

## Versions (npm view)
| Package | Version |
|---|---|
| `@mozilla/readability` | 0.6.0 (last published 2025-03) |
| `linkedom` | 0.18.13 |
| `sanitize-html` | 2.18.1 |
| `fflate` | 0.8.3 |
| `@cloudflare/puppeteer` | 1.4.0 |
| `wrangler` | 4.151.0 |
| `hono` | 4.13.13 |
| `dompurify` | 3.4.17 (not tested; needs a DOM window, so skip it) |

## 1. Readability + linkedom (VERIFIED in wrangler dev)
It works with no shims. I did not need to add `document.documentElement`, `DOMParser` or globals. `isProbablyReaderable`, `parse()` and the title and excerpt fields all returned correct values. `<script>` was stripped from the output.

```ts
import { parseHTML } from 'linkedom';
import { Readability, isProbablyReaderable } from '@mozilla/readability';

const { document } = parseHTML(html);              // use parseHTML, not new DOMParser
try { Object.defineProperty(document, 'baseURI', { value: finalUrl }); } catch {}
if (isProbablyReaderable(document as any)) {
  const a = new Readability(document as any, { charThreshold: 200 }).parse();
  // a: { title, content (HTML string), textContent, length, excerpt, byline, siteName, lang, publishedTime }
}
```

Gotchas:
- Cast `document as any`, because the linkedom types don't match the DOM lib types.
- Relative links and images are resolved by Readability against `document.baseURI`, and linkedom has no real baseURI.
  - Setting it as above ran without error.
  - UNVERIFIED: I did not check that relative URLs actually came out absolute.
  - Safe fallback: inject `<base href>` into the head before parsing, or post-process `a[href]` and `img[src]` with `new URL(x, finalUrl)` in the sanitize step.
- `Readability.parse()` mutates the document, so parse once per document.
- Readability can only use `<meta>` and JSON-LD that is in the HTML. Client-rendered SPAs return little, which is where Browser Run comes in.
- Bundle size: Readability, linkedom, sanitize-html and fflate together come to 915 KiB raw and 224 KiB gzip (`wrangler deploy --dry-run`). That is well under the 3 MB free / 10 MB paid limit.
- Limit the input size (see the safe-fetch section below). Parsing a 5 MB DOM costs real CPU time, so put extraction in a Queue consumer rather than the request path.

## 2. Sanitizer
- **`sanitize-html` 2.18.1 bundles and runs on Workers (VERIFIED).**
  - It is htmlparser2-based with no DOM, and it needed no flags beyond `nodejs_compat`.
  - It stripped `<script>`, `onerror` and so on in my test.
  - It is the simplest choice: run Readability, then sanitize `art.content`.
- A custom allowlist walker on linkedom is also possible, but it is more code and more risk, so I would not do it.
- UNVERIFIED: `sanitize-html` pulls in `postcss` for `<style>` handling. That is the likely part of the bundle size.

```ts
import sanitizeHtml from 'sanitize-html';
const clean = sanitizeHtml(art.content, {
  allowedTags: ['h1','h2','h3','h4','p','a','img','ul','ol','li','blockquote','pre','code','em','strong','br','hr','figure','figcaption','table','thead','tbody','tr','th','td','sup','sub'],
  allowedAttributes: { a: ['href','title'], img: ['src','alt','title','width','height'] },
  allowedSchemes: ['https','http'],
  transformTags: { a: sanitizeHtml.simpleTransform('a', { rel: 'noopener noreferrer nofollow', target: '_blank' }) },
});
```

## 3. fflate zip (VERIFIED)
`zipSync` ran in the Worker. Use `zipSync`/`strToU8` for small exports and `Zip` + `ZipDeflate` streaming for large ones. Note that streamed writes can be passed to R2 `put` through a `TransformStream`. UNVERIFIED: the streaming variant.

```ts
import { zipSync, strToU8 } from 'fflate';
const zip = zipSync({ 'items.json': strToU8(JSON.stringify(items)) }, { level: 6 });
```

## 4. Images binding (docs-verified; not run, because local mode is low-fidelity)
```jsonc
{ "images": { "binding": "IMAGES" }, "cache": { "enabled": true } }   // cache block is "recommended" per docs
```

```ts
const r = await fetch(imgUrl);                               // go through safeFetch
const out = await env.IMAGES.input(r.body!)                  // ReadableStream, max 20 MB input
  .transform({ width: 1200 })                                // also height, fit, rotate, blur
  .output({ format: 'image/webp', quality: 80 });
await env.R2.put(key, out.image(), { httpMetadata: { contentType: out.contentType() } });
// or: return out.response({ headers: { 'Cache-Control': 'public, max-age=31536000' } });
const meta = await env.IMAGES.info(stream);                  // free; gives format, fileSize, width, height
```
- UNVERIFIED: `out.image()` and `out.contentType()`. The docs I read only showed `.response()`. Check the type definitions in `@cloudflare/workers-types` before relying on them.
- You must call `.output()`, since there is no default format.
- Pricing:
  - Billing is per unique transformation (source image plus parameters), once per calendar month.
  - Free plan: 5,000 per month, with errors (code 9422) past that and no charge.
  - Paid plan: 5,000 included, then $0.50 per 1,000.
  - `.info()` is free.
  - Local dev is not billed.
- `wrangler dev` offline mode supports only `width`, `height`, `rotate` and `format`. Use `--remote` for full fidelity.
- A good Sroka design is to transform once at ingest and store the result in R2, so each image is billed once.

## 5. Browser Run (formerly Browser Rendering)
Two options:

**A. REST or binding Quick Action `/content` (simpler, recommended).**
- Endpoint: `POST https://api.cloudflare.com/client/v4/accounts/<acct>/browser-run/content`
- Auth: bearer token with the `Browser Run - Edit` permission.
- Body: `{ url | html, gotoOptions:{waitUntil:"networkidle0"|"networkidle2"}, waitForSelector, rejectResourceTypes:["image","media","font"], rejectRequestPattern, userAgent, cookies, setExtraHTTPHeaders }`
- Inside a Worker you can use the binding with no token: `await env.BROWSER.quickAction("content", { url, rejectResourceTypes: ["image"] })`.
  - This needs compat date 2026-03-24 or later.
  - It does not work in local `wrangler dev`. Use `--remote`, or `"remote": true` on the binding.
- UNVERIFIED: the response shape. The docs page does not document it. The REST API probably returns a `{success, result: "<html>"}` envelope, so test it once with curl.
- Billed in browser hours only.

**B. `@cloudflare/puppeteer` binding (sessions).**
```jsonc
{ "browser": { "binding": "BROWSER" }, "compatibility_flags": ["nodejs_compat"] }
// docs example uses nodejs_compat_v2; both are default-on for compat date >= 2026-08-04
```
```ts
import puppeteer from '@cloudflare/puppeteer';
const b = await puppeteer.launch(env.BROWSER);
const p = await b.newPage(); await p.goto(url, { waitUntil: 'networkidle0' });
const html = await p.content(); await b.close();
```
- Sessions idle out after 1 minute, extendable to 20 minutes with `keep_alive`.
- Billed for browser hours and concurrent browsers.
- The Puppeteer docs page I fetched said "v1.1.0, based on Puppeteer 22.13.1", while npm shows 1.4.0. Trust npm.

**Recommendation:** use Quick Action `/content` as a fallback only. First try the plain fetch plus Readability. If the result is empty or under a character threshold, fall back to Browser Run, then run Readability on the returned HTML.

Pricing:
- Free plan: 10 minutes per day and 3 concurrent browsers.
- Paid plan: 10 hours per month included, then $0.09 per hour, plus 10 concurrent browsers included (then $2 each).
- UNVERIFIED: REST requests-per-minute limits.

## 6. Safe fetch (VERIFIED to type-check with tsc; not run against live hosts)
Full code is at `/private/tmp/claude-501/sroka-research/extract/src/safe.ts`. The core logic:
- Loop up to N times with `fetch(url, { redirect:'manual', signal: AbortSignal.timeout(10000) })`.
- On a 3xx, read `location`, cancel the body, and resolve it with `new URL(loc, url)`. Re-run the URL check on every hop.
- Check `content-length`, then stream with `getReader()` and count bytes. Call `reader.cancel()` when over the cap, because `content-length` can lie or be absent.
- Collect the chunks into a single `Uint8Array`, then use `new TextDecoder(charsetFromHeaderOrMeta).decode()`.

URL check (SSRF):
- Allow only `http:` and `https:` and ports 80 and 443.
- Block IP-literal hosts, `localhost`, `*.internal`, and the IPv4 and IPv6 private and loopback ranges.
- Workers `fetch()` cannot reach private networks or the Workers' own zone origin anyway, but keep the check as defense in depth.
- DNS-rebinding protection is limited from inside Workers, because you cannot resolve the hostname yourself.

Other checks:
- Require a `content-type` of `text/html` or `application/xhtml+xml` before parsing.
- Send a custom `User-Agent` and `Accept` header.
- Use a 5 MB cap for HTML and a 20 MB cap for images, since the Images binding input limit is 20 MB.
- Do not forward cookies or `Authorization`.
- Workers does not follow `redirect:'manual'` in a way that exposes the `Response.url` of the final hop, so track the URL yourself (as the loop above does). Use that tracked URL as the canonical URL and as the base for resolving links.

## Suggested pipeline
1. A Queue consumer calls `safeFetch`.
2. Parse with linkedom and run Readability.
3. If the result is under the threshold, retry via Browser Run `/content`.
4. Pass the result through `sanitize-html`.
5. For each image, call `safeFetch`, then `IMAGES` to webp, then R2 `put`.
6. Save the title, excerpt and content R2 key to the user's Durable Object.
