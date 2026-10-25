import type { Extracted } from "./extract.ts";
import { normalizeText } from "./extract.ts";
import { formatTweetDate } from "./twitter.ts";

/** Comment threads (Reddit, Hacker News) as post cards: shared model + renderer. Decisions D13. */

export const MAX_COMMENTS = 200;
/** Reply levels shown below a top-level comment (or below the saved comment); deeper ones become a link. */
export const MAX_DEPTH = 3;

export interface ThreadPost {
  title: string | null;
  author: string | null;
  /** Community (r/x); shown before the author and in the byline. */
  sub: string | null;
  flair: string | null;
  score: number | null;
  comments: number | null;
  created: string | null;
  permalink: string | null;
  bodyHtml: string;
  images: string[];
  /** External link of a link post. */
  link: string | null;
  video: boolean;
}

export interface ThreadComment {
  id: string | null;
  author: string | null;
  score: number | null;
  created: string | null;
  permalink: string | null;
  bodyHtml: string;
  deleted: boolean;
  op: boolean;
  children: ThreadComment[];
  /** Replies Reddit didn't send ("load more"). */
  more: number;
}

export interface Thread {
  post: ThreadPost;
  comments: ThreadComment[];
  /** Top-level comments Reddit didn't send. */
  more: number;
  focusId: string | null;
}

export interface DiscussionSite {
  /** "Reddit", "Hacker News": siteName and the "View on …" links. */
  name: string;
  user(name: string): { href: string; label: string };
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function plural(n: number, one: string) {
  return `${n.toLocaleString("en-US")} ${one}${n === 1 ? "" : "s"}`;
}

/** Plain text of a small HTML fragment (comment/post bodies). */
export function htmlText(html: string): string {
  return normalizeText(
    html
      .replace(/<(br|\/p|\/li|\/h\d|\/blockquote|\/pre)\b[^>]*>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .replace(/&nbsp;/g, " ")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&#x27;/g, "'")
      .replace(/&amp;/g, "&"),
  );
}

// ---------------------------------------------------------------------------------------------------

function dateHtml(iso: string | null, href: string | null): string {
  if (!iso) return "";
  const t = `<time datetime="${esc(iso)}">${esc(formatTweetDate(iso))}</time>`;
  return `<span class="sr-post-date"> · ${href ? `<a href="${esc(href)}">${t}</a>` : t}</span>`;
}

function userLink(site: DiscussionSite, u: string): string {
  const { href, label } = site.user(u);
  return `<a href="${esc(href)}">${esc(label)}</a>`;
}

function postCard(p: ThreadPost, site: DiscussionSite, text: string[]): string {
  const who = [p.sub ? `<strong>${esc(p.sub)}</strong>` : null, p.author ? userLink(site, p.author) : null].filter(Boolean).join(" · ");
  const head = `<p class="sr-post-head"><span class="sr-post-who">${who}</span>${dateHtml(p.created, p.permalink)}</p>`;
  const body: string[] = [];
  if (p.flair) body.push(`<p><small>${esc(p.flair)}</small></p>`);
  if (p.bodyHtml) {
    body.push(`<div>${p.bodyHtml}</div>`);
    text.push(htmlText(p.bodyHtml));
  }
  for (const src of p.images) body.push(`<figure><img src="${esc(src)}" alt=""></figure>`);
  if (p.link) body.push(`<p><a href="${esc(p.link)}">${esc(p.link)}</a></p>`);
  if (p.video && p.permalink) body.push(`<p><a href="${esc(p.permalink)}">Watch the video on ${esc(site.name)}</a></p>`);
  const stats = [p.score !== null ? plural(p.score, "point") : null, p.comments !== null ? plural(p.comments, "comment") : null].filter(Boolean);
  const statsHtml = stats.length ? `<p class="sr-post-stats"><small>${esc(stats.join(" · "))}</small></p>` : "";
  return `<div class="sr-post">${head}<div class="sr-post-body">${body.join("\n")}</div>${statsHtml}</div>`;
}

const countAll = (cs: ThreadComment[]): number => cs.reduce((n, c) => n + 1 + c.more + countAll(c.children), 0);

function hasFocus(c: ThreadComment, focusId: string): boolean {
  return c.id === focusId || c.children.some((k) => hasFocus(k, focusId));
}

interface RenderCtx {
  site: DiscussionSite;
  focusId: string | null;
  text: string[];
  focusText: string | null;
  focusAuthor: string | null;
}

/** One comment (card at depth 0, nested reply below), its replies down to `limit`. */
function commentHtml(c: ThreadComment, depth: number, limit: number, ctx: RenderCtx): string {
  const focus = !!ctx.focusId && c.id === ctx.focusId;
  // Below the saved comment, depth restarts so its replies get the full MAX_DEPTH levels.
  const childLimit = focus ? depth + MAX_DEPTH : limit;
  const replies: string[] = [];
  let hidden = c.more;
  if (depth < childLimit) for (const k of c.children) replies.push(commentHtml(k, depth + 1, childLimit, ctx));
  else hidden += countAll(c.children);
  if (hidden && c.permalink) {
    replies.push(`<p class="sr-post-stats"><small><a href="${esc(c.permalink)}">${esc(`${hidden.toLocaleString("en-US")} more ${hidden === 1 ? "reply" : "replies"}`)} on ${esc(ctx.site.name)}</a></small></p>`);
  }
  const repliesHtml = replies.length ? `<div class="sr-replies">${replies.join("\n")}</div>` : "";
  const cls = `${depth === 0 ? "sr-post" : "sr-reply"}${focus ? " sr-post-focus" : ""}`;
  if (c.deleted) {
    // Keep a placeholder only when it holds the thread together.
    return repliesHtml ? `<div class="${cls}"><p class="sr-post-head"><span class="sr-post-who">[deleted]</span></p>${repliesHtml}</div>` : "";
  }
  const t = htmlText(c.bodyHtml);
  ctx.text.push(t);
  if (focus) {
    ctx.focusText = t;
    ctx.focusAuthor = c.author;
  }
  const who = `<strong>${c.author ? userLink(ctx.site, c.author) : "[deleted]"}</strong>${c.op ? " <small>OP</small>" : ""}`;
  const head = `<p class="sr-post-head"><span class="sr-post-who">${who}</span>${dateHtml(c.created, c.permalink)}</p>`;
  const stats = c.score !== null ? `<p class="sr-post-stats"><small>${esc(plural(c.score, "point"))}</small></p>` : "";
  return `<div class="${cls}">${head}<div class="sr-post-body">${c.bodyHtml}</div>${stats}${repliesHtml}</div>`;
}

/**
 * Discussion thread as post cards: the post in `div.sr-thread`, then `div.sr-comments` of top-level comment cards
 * with replies nested (`div.sr-replies` > `div.sr-reply`) MAX_DEPTH levels deep. With `focusId` in the tree (a
 * comment link) its parents are shown whole and the comment is highlighted. Decisions D13.
 */
export function renderThread(th: Thread, site: DiscussionSite, lang: string | null, ogImage: string | null): Extracted | null {
  const { post } = th;
  const postText: string[] = [];
  const ctx: RenderCtx = { site, focusId: th.focusId, text: [], focusText: null, focusAuthor: null };
  // On a comment permalink the parents chain is context: show it whole, then MAX_DEPTH levels below the comment.
  const focused = !!th.focusId && th.comments.some((c) => hasFocus(c, th.focusId!));
  if (!focused) ctx.focusId = null;
  const limit = focused ? Number.MAX_SAFE_INTEGER : MAX_DEPTH;
  const cards = th.comments.map((c) => commentHtml(c, 0, limit, ctx)).filter(Boolean);

  const parts = [`<div class="sr-thread">\n${postCard(post, site, postText)}\n</div>`];
  if (cards.length) parts.push(`<h2>Comments</h2>\n<div class="sr-comments">\n${cards.join("\n")}\n</div>`);
  const shown = ctx.text.length;
  const total = post.comments ?? shown + th.more;
  const foot: string[] = [];
  if (post.permalink) {
    const label = focused
      ? `View all ${plural(total, "comment")} on ${site.name}`
      : total > shown
        ? `${plural(total, "comment")} · View all on ${site.name}`
        : `View on ${site.name}`;
    foot.push(`<a href="${esc(post.permalink)}">${esc(label)}</a>`);
  }
  if (foot.length) parts.push(`<p class="sr-thread-foot"><small>${foot.join(" · ")}</small></p>`);

  const text = normalizeText([post.title ?? "", ...postText, ...ctx.text].filter(Boolean).join("\n\n"));
  if (text.length < 20 && !post.images.length) return null;
  const author = focused ? ctx.focusAuthor : post.author;
  return {
    title: post.title,
    byline: [author ? site.user(author).label : null, post.sub ? `in ${post.sub}` : null].filter(Boolean).join(" ") || null,
    siteName: site.name,
    lang,
    publishedTime: post.created,
    excerpt: ((focused ? ctx.focusText : null) || postText[0] || ctx.text[0] || "").slice(0, 300) || null,
    contentHtml: parts.join("\n"),
    text,
    leadImage: post.images[0] ?? ogImage,
  };
}

