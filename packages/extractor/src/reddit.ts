import { parseHTML } from "linkedom";
import type { Extracted } from "./extract.ts";
import { normalizeText } from "./extract.ts";
import { htmlText, MAX_COMMENTS, renderThread, type DiscussionSite, type ThreadComment as RComment, type ThreadPost as RPost, type Thread as RThread } from "./discussion.ts";

/**
 * Reddit from the extension's capture (Reddit serves servers a "Prove your humanity" challenge). Readability keeps
 * only the post body and drops the comments, so build the article ourselves as post cards (same classes as X posts,
 * decisions D11/D13): the post, then the comment tree, replies nested up to MAX_DEPTH levels.
 * Source, best first: the thread JSON the extension embeds (`script#sroka-reddit-json`, Reddit's own `.json` of the
 * page, fetched in the page; the rendered page lazy-loads comments), else the shreddit markup. On a comment permalink
 * (`/comments/{post}/{slug}/{comment}/`) the thread is that comment's parents, the comment (highlighted) and its
 * replies. Returns null when neither source is there (callers fall back to Readability).
 */


type Doc = ReturnType<typeof parseHTML>["document"];
/** Minimal linkedom element surface (works under DOM lib and workers-types). */
interface El {
  tagName: string;
  innerHTML: string;
  textContent: string | null;
  parentElement: El | null;
  getAttribute(name: string): string | null;
  hasAttribute(name: string): boolean;
  querySelector(sel: string): El | null;
  querySelectorAll(sel: string): Iterable<El>;
  closest(sel: string): El | null;
}

export function isRedditUrl(url: string): boolean {
  try {
    return /(^|\.)reddit\.com$/i.test(new URL(url).hostname);
  } catch {
    return false;
  }
}

/** Comment id of a comment permalink (`/r/x/comments/{post}/{slug}/{comment}/`), else null. */
export function redditCommentId(url: string): string | null {
  try {
    return /\/comments\/[^/]+\/[^/]*\/([a-z0-9]+)\/?$/i.exec(new URL(url).pathname)?.[1] ?? null;
  } catch {
    return null;
  }
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const attr = (el: El, name: string) => el.getAttribute(name)?.trim() || null;
const all = (root: El | Doc, sel: string): El[] => [...((root as El).querySelectorAll(sel) as Iterable<El>)];

function abs(href: string | null | undefined, base: string): string | null {
  if (!href) return null;
  try {
    return new URL(href, base).href;
  } catch {
    return null;
  }
}

function plural(n: number, one: string) {
  return `${n.toLocaleString("en-US")} ${one}${n === 1 ? "" : "s"}`;
}

const REDDIT: DiscussionSite = {
  name: "Reddit",
  user: (u) => ({ href: `https://www.reddit.com/user/${encodeURIComponent(u)}`, label: `u/${u}` }),
};

function num(el: El, name: string): number | null {
  const v = Number(attr(el, name));
  return Number.isFinite(v) && attr(el, name) !== null ? v : null;
}

function isRemovedText(html: string): boolean {
  const t = htmlText(html);
  return !t || t === "[deleted]" || t === "[removed]";
}

const REDDIT_MEDIA = /^https:\/\/(i|preview|external-preview)\.redd\.it\//;
const isRedditLink = (href: string) => /^https:\/\/((www|old|new|np)\.)?reddit\.com\//.test(href) || /^https:\/\/(i|v|preview)\.redd\.it\//.test(href);

// ---- thread from Reddit's JSON (embedded by the extension) -----------------------------------------------------

type J = Record<string, unknown>;
const obj = (v: unknown): J | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as J) : null);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v : null);
const int = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const listing = (v: unknown): J[] =>
  (Array.isArray(obj(obj(v)?.data)?.children) ? (obj(v)!.data as J).children as unknown[] : []).map(obj).filter((x): x is J => !!x);
const utc = (v: unknown): string | null => (int(v) !== null ? new Date(int(v)! * 1000).toISOString() : null);

function jsonImages(d: J): string[] {
  const out: string[] = [];
  const meta = obj(d.media_metadata);
  const items = Array.isArray(obj(d.gallery_data)?.items) ? ((d.gallery_data as J).items as unknown[]) : [];
  for (const it of items) {
    const m = obj(meta?.[str(obj(it)?.media_id) ?? ""]);
    const src = str(obj(m?.s)?.u) ?? str(obj(m?.s)?.gif);
    if (src) out.push(src);
  }
  const url = str(d.url);
  if (!out.length && url && d.post_hint === "image") out.push(url);
  if (!out.length && (d.is_video || d.post_hint === "hosted:video" || d.post_hint === "rich:video")) {
    const src = str(obj(obj((obj(d.preview)?.images as unknown[] | undefined)?.[0])?.source)?.url);
    if (src) out.push(src);
  }
  return out.filter((u) => REDDIT_MEDIA.test(u)).slice(0, 20);
}

function jsonComment(c: J, base: string, out: { n: number }): RComment | null {
  const d = obj(c.data);
  if (!d) return null;
  if (c.kind === "more") return null;
  if (c.kind !== "t1" || out.n >= MAX_COMMENTS) return null;
  if (d.stickied && d.author === "AutoModerator") return null;
  out.n++;
  const bodyHtml = str(d.body_html) ?? "";
  const author = str(d.author);
  const node: RComment = {
    id: str(d.id),
    author: author === "[deleted]" ? null : author,
    score: int(d.score),
    created: utc(d.created_utc),
    permalink: abs(str(d.permalink), base),
    bodyHtml,
    deleted: author === "[deleted]" || isRemovedText(bodyHtml),
    op: d.is_submitter === true,
    children: [],
    more: 0,
  };
  for (const r of listing(d.replies)) {
    if (r.kind === "more") node.more += int(obj(r.data)?.count) ?? 0;
    else {
      const child = jsonComment(r, base, out);
      if (child) node.children.push(child);
    }
  }
  return node;
}

function threadFromJson(json: unknown, url: string): RThread | null {
  if (!Array.isArray(json) || json.length < 2) return null;
  const p = listing(json[0]).find((c) => c.kind === "t3");
  const d = obj(p?.data);
  if (!d) return null;
  const link = str(d.url);
  const post: RPost = {
    title: str(d.title),
    author: str(d.author),
    sub: str(d.subreddit_name_prefixed),
    flair: str(d.link_flair_text),
    score: int(d.score),
    comments: int(d.num_comments),
    created: utc(d.created_utc),
    permalink: abs(str(d.permalink), url),
    bodyHtml: str(d.selftext_html) ?? "",
    images: jsonImages(d),
    link: link && !d.is_self && !isRedditLink(abs(link, url) ?? "") && !REDDIT_MEDIA.test(link) ? abs(link, url) : null,
    video: d.is_video === true,
  };
  const counter = { n: 0 };
  const comments: RComment[] = [];
  let more = 0;
  for (const c of listing(json[1])) {
    if (c.kind === "more") more += int(obj(c.data)?.count) ?? 0;
    else {
      const node = jsonComment(c, url, counter);
      if (node) comments.push(node);
    }
  }
  return { post, comments, more, focusId: redditCommentId(url) };
}

function embeddedJson(doc: Doc): unknown {
  const raw = doc.querySelector("script#sroka-reddit-json")?.textContent;
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// ---- thread from the rendered shreddit markup ------------------------------------------------------------------

/** First element matching `sel` inside `owner` that belongs to `owner` itself (not to a nested `ownerSel`). */
function own(owner: El, sel: string, ownerSel: string): El | null {
  for (const el of all(owner, sel)) if (el.closest(ownerSel) === owner) return el;
  return null;
}

/** Post images: gallery / single image, Reddit-hosted only (skips avatars, icons, emoji). */
function postImages(post: El, base: string): string[] {
  const out: string[] = [];
  for (const img of all(post, "img")) {
    const src = abs(attr(img, "src") ?? attr(img, "data-lazy-src"), base);
    if (!src || !REDDIT_MEDIA.test(src)) continue;
    const key = src.split("?")[0]!;
    if (!out.some((u) => u.split("?")[0] === key)) out.push(src);
  }
  for (const player of all(post, "shreddit-player, shreddit-player-2")) {
    const poster = abs(attr(player, "poster") ?? attr(player, "preview"), base);
    if (poster && !out.includes(poster)) out.push(poster);
  }
  return out.slice(0, 20);
}

function domTime(owner: El, ownerSel: string, base: string | null): string | null {
  const ts = own(owner, "faceplate-timeago", ownerSel);
  return (ts && attr(ts, "ts")) ?? base;
}

function threadFromDom(doc: Doc, post: El, url: string): RThread {
  const href = abs(attr(post, "content-href"), url);
  const sub = attr(post, "subreddit-prefixed-name") ?? (attr(post, "subreddit-name") ? `r/${attr(post, "subreddit-name")}` : null);
  const body = own(post, '[slot="text-body"]', "shreddit-post");
  const author = attr(post, "author");
  const p: RPost = {
    title: attr(post, "post-title") ?? doc.querySelector("h1")?.textContent?.trim() ?? null,
    author,
    sub,
    flair: null,
    score: num(post, "score"),
    comments: num(post, "comment-count"),
    created: attr(post, "created-timestamp"),
    permalink: abs(attr(post, "permalink"), url),
    bodyHtml: body?.innerHTML ?? "",
    images: postImages(post, url),
    link: href && !isRedditLink(href) ? href : null,
    video: all(post, "shreddit-player, shreddit-player-2").length > 0,
  };

  const nodes = new Map<El, RComment>();
  const roots: RComment[] = [];
  for (const el of all(doc, "shreddit-comment")) {
    if (nodes.size >= MAX_COMMENTS) break;
    const cBody = own(el, '[slot="comment"]', "shreddit-comment");
    const cAuthor = attr(el, "author");
    const node: RComment = {
      id: attr(el, "thingid")?.replace(/^t1_/, "") ?? null,
      author: cAuthor === "[deleted]" ? null : cAuthor,
      score: num(el, "score"),
      created: domTime(el, "shreddit-comment", attr(el, "created")),
      permalink: abs(attr(el, "permalink"), url),
      bodyHtml: cBody?.innerHTML ?? "",
      deleted: el.hasAttribute("is-comment-deleted") || cAuthor === "[deleted]" || isRemovedText(cBody?.innerHTML ?? ""),
      op: !!author && cAuthor === author,
      children: [],
      more: 0,
    };
    nodes.set(el, node);
    const parentEl = el.parentElement?.closest("shreddit-comment") ?? null;
    const parent = parentEl ? nodes.get(parentEl) : undefined;
    (parent ? parent.children : roots).push(node);
  }
  return { post: p, comments: roots, more: 0, focusId: redditCommentId(url) };
}

/** Listing page (front page, subreddit): link list of the visible posts. */
function listingHtml(posts: El[], base: string): { html: string; text: string } {
  const items: string[] = [];
  const text: string[] = [];
  for (const p of posts) {
    const title = attr(p, "post-title");
    const link = abs(attr(p, "permalink"), base);
    if (!title || !link) continue;
    const meta = [attr(p, "subreddit-prefixed-name"), num(p, "score") !== null ? plural(num(p, "score")!, "point") : null, num(p, "comment-count") !== null ? plural(num(p, "comment-count")!, "comment") : null]
      .filter(Boolean)
      .join(" · ");
    items.push(`<li><a href="${esc(link)}">${esc(title)}</a>${meta ? `<br><small>${esc(meta)}</small>` : ""}</li>`);
    text.push(title);
  }
  return { html: items.length ? `<ul>${items.join("\n")}</ul>` : "", text: text.join("\n") };
}

export function extractReddit(html: string, url: string): Extracted | null {
  if (!isRedditUrl(url)) return null;
  const hasJson = html.includes('id="sroka-reddit-json"');
  if (!hasJson && !html.includes("<shreddit-post")) return null;
  const { document } = parseHTML(html);
  const ogImage = abs(document.querySelector('meta[property="og:image"]')?.getAttribute("content") ?? null, url);
  const lang = document.documentElement?.getAttribute("lang") || null;
  const isThread = /\/comments\//.test(new URL(url).pathname);

  if (isThread && hasJson) {
    const th = threadFromJson(embeddedJson(document), url);
    const ex = th && renderThread(th, REDDIT, lang, ogImage);
    if (ex) return ex;
  }

  const posts = all(document, "shreddit-post");
  if (!posts.length) return null;
  if (!isThread) {
    const list = listingHtml(posts, url);
    if (!list.html) return null;
    const docTitle = document.querySelector("title")?.textContent?.trim() || "Reddit";
    return { title: docTitle, byline: null, siteName: "Reddit", lang, publishedTime: null, excerpt: null, contentHtml: list.html, text: list.text, leadImage: ogImage };
  }
  // A thread page has one post (plus, sometimes, "related" posts after the comments).
  return renderThread(threadFromDom(document, posts[0]!, url), REDDIT, lang, ogImage);
}
