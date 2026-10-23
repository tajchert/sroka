import { parseHTML } from "linkedom";
import type { Extracted } from "./extract.ts";
import { normalizeText } from "./extract.ts";

/**
 * Reddit (new UI, "shreddit") from a rendered page — normally the extension's capture, since Reddit serves servers
 * a "Prove your humanity" challenge. Readability keeps only the post body and drops the comment tree, so build the
 * article ourselves: post header, body/media, then comments nested as blockquotes. Returns null when the page has
 * no shreddit markup (callers fall back to Readability).
 */

const MAX_COMMENTS = 300;
/** Deeper replies are still kept, but stop indenting so text doesn't collapse into a narrow column. */
const MAX_INDENT = 6;

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

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const attr = (el: El, name: string) => el.getAttribute(name)?.trim() || null;
const all = (root: El | Doc, sel: string): El[] => [...((root as El).querySelectorAll(sel) as Iterable<El>)];

function abs(href: string | null, base: string): string | null {
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

function num(el: El, name: string): number | null {
  const v = Number(attr(el, name));
  return Number.isFinite(v) && attr(el, name) !== null ? v : null;
}

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
    if (!src || !/^https:\/\/(i|preview|external-preview)\.redd\.it\//.test(src)) continue;
    const key = src.split("?")[0]!;
    if (!out.some((u) => u.split("?")[0] === key)) out.push(src);
  }
  for (const player of all(post, "shreddit-player, shreddit-player-2")) {
    const poster = abs(attr(player, "poster") ?? attr(player, "preview"), base);
    if (poster && !out.includes(poster)) out.push(poster);
  }
  return out.slice(0, 20);
}

function postHtml(post: El, base: string): { html: string; text: string } {
  const parts: string[] = [];
  const sub = attr(post, "subreddit-prefixed-name") ?? (attr(post, "subreddit-name") ? `r/${attr(post, "subreddit-name")}` : null);
  const author = attr(post, "author");
  const score = num(post, "score");
  const comments = num(post, "comment-count");
  const meta = [sub, author ? `u/${author}` : null, score !== null ? plural(score, "point") : null, comments !== null ? plural(comments, "comment") : null]
    .filter(Boolean)
    .join(" · ");
  if (meta) parts.push(`<p><small>${esc(meta)}</small></p>`);

  const body = own(post, '[slot="text-body"]', "shreddit-post");
  if (body) parts.push(`<div>${body.innerHTML}</div>`);
  for (const src of postImages(post, base)) parts.push(`<figure><img src="${esc(src)}" alt=""></figure>`);

  const href = abs(attr(post, "content-href"), base);
  if (href && !/^https:\/\/((www|old)\.)?reddit\.com\//.test(href) && !/^https:\/\/(i|v|preview)\.redd\.it\//.test(href)) {
    parts.push(`<p><a href="${esc(href)}">${esc(href)}</a></p>`);
  }
  if (all(post, "shreddit-player, shreddit-player-2").length) {
    const permalink = abs(attr(post, "permalink"), base);
    if (permalink) parts.push(`<p><a href="${esc(permalink)}">Watch the video on Reddit</a></p>`);
  }
  return { html: parts.join("\n"), text: normalizeText(body?.textContent ?? "") };
}

interface CommentNode {
  el: El;
  children: CommentNode[];
}

function commentTree(doc: Doc): CommentNode[] {
  const nodes = new Map<El, CommentNode>();
  const roots: CommentNode[] = [];
  for (const el of all(doc, "shreddit-comment")) {
    if (nodes.size >= MAX_COMMENTS) break;
    const node: CommentNode = { el, children: [] };
    nodes.set(el, node);
    const parentEl = el.parentElement?.closest("shreddit-comment") ?? null;
    const parent = parentEl ? nodes.get(parentEl) : undefined;
    (parent ? parent.children : roots).push(node);
  }
  return roots;
}

function isDeleted(c: El, body: El | null): boolean {
  const author = attr(c, "author");
  const text = normalizeText(body?.textContent ?? "");
  return c.hasAttribute("is-comment-deleted") || author === "[deleted]" || !text || text === "[deleted]" || text === "[removed]";
}

function commentsHtml(nodes: CommentNode[], depth: number, text: string[]): string {
  const out: string[] = [];
  for (const { el, children } of nodes) {
    const body = own(el, '[slot="comment"]', "shreddit-comment");
    const replies = children.length ? commentsHtml(children, depth + 1, text) : "";
    if (isDeleted(el, body)) {
      // Keep a placeholder only when it holds the thread together.
      if (replies) out.push(`<div><p><small>[deleted]</small></p>${replies}</div>`);
      continue;
    }
    const author = attr(el, "author");
    const score = num(el, "score");
    const head = [author ? `<strong>u/${esc(author)}</strong>` : null, score !== null ? esc(plural(score, "point")) : null].filter(Boolean).join(" · ");
    text.push(normalizeText(body?.textContent ?? ""));
    const inner = `<p><small>${head}</small></p>${body?.innerHTML ?? ""}${replies}`;
    out.push(depth > 0 && depth <= MAX_INDENT ? `<blockquote>${inner}</blockquote>` : `<div>${inner}</div>`);
  }
  return out.join("\n");
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
  if (!isRedditUrl(url) || !html.includes("<shreddit-post")) return null;
  const { document } = parseHTML(html);
  const posts = all(document, "shreddit-post");
  if (!posts.length) return null;
  const ogImage = abs(document.querySelector('meta[property="og:image"]')?.getAttribute("content") ?? null, url);
  const lang = document.documentElement?.getAttribute("lang") || null;

  // A thread page has one post (plus, sometimes, "related" posts after the comments).
  const isThread = /\/comments\//.test(new URL(url).pathname);
  if (!isThread) {
    const list = listingHtml(posts, url);
    if (!list.html) return null;
    const docTitle = document.querySelector("title")?.textContent?.trim() || "Reddit";
    return { title: docTitle, byline: null, siteName: "Reddit", lang, publishedTime: null, excerpt: null, contentHtml: list.html, text: list.text, leadImage: ogImage };
  }

  const post = posts[0]!;
  const title = attr(post, "post-title") ?? document.querySelector("h1")?.textContent?.trim() ?? null;
  const author = attr(post, "author");
  const sub = attr(post, "subreddit-prefixed-name");
  const { html: postBody, text: postText } = postHtml(post, url);
  const commentText: string[] = [];
  const comments = commentsHtml(commentTree(document), 0, commentText);

  const contentHtml = [postBody, comments ? `<hr>\n<h2>Comments</h2>\n${comments}` : ""].filter(Boolean).join("\n");
  const text = normalizeText([title ?? "", postText, ...commentText].filter(Boolean).join("\n\n"));
  if (text.length < 20) return null;
  const firstImage = /<img src="([^"]+)"/.exec(postBody)?.[1] ?? null;

  return {
    title,
    byline: [author ? `u/${author}` : null, sub ? `in ${sub}` : null].filter(Boolean).join(" ") || null,
    siteName: "Reddit",
    lang,
    publishedTime: attr(post, "created-timestamp"),
    excerpt: (postText || commentText[0] || "").slice(0, 300) || null,
    contentHtml,
    text,
    leadImage: firstImage?.replace(/&amp;/g, "&") ?? ogImage,
  };
}
