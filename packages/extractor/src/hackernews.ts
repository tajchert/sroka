import { MAX_COMMENTS, renderThread, type DiscussionSite, type Thread, type ThreadComment, type ThreadPost } from "./discussion.ts";
import type { Extracted } from "./extract.ts";
import { FetchError, safeFetch, type SafeFetchOptions } from "./safe-fetch.ts";

/**
 * Hacker News items (`news.ycombinator.com/item?id=`) from the public APIs (decisions D13): the story and its whole
 * comment tree from Algolia `hn.algolia.com/api/v1/items/{storyId}` (replies in posting order), top-level comments
 * reordered by HN's ranking from the official Firebase item (`kids`). A comment id renders its story with that
 * comment's parents, the comment (highlighted) and its replies. Only the item id leaves our system.
 */

const ALGOLIA_ITEM = "https://hn.algolia.com/api/v1/items/";
const FIREBASE_ITEM = "https://hacker-news.firebaseio.com/v0/item/";
/** Big threads (1000+ comments) are several MB of JSON. */
const MAX_JSON_BYTES = 20 * 1024 * 1024;

export const HN: DiscussionSite = {
  name: "Hacker News",
  user: (u) => ({ href: `https://news.ycombinator.com/user?id=${encodeURIComponent(u)}`, label: u }),
};

/** Item id of a Hacker News item URL, else null. */
export function hnItemId(url: string): string | null {
  try {
    const u = new URL(url);
    if (!/^(www\.)?news\.ycombinator\.com$/i.test(u.hostname) || u.pathname !== "/item") return null;
    const id = u.searchParams.get("id");
    return id && /^\d{1,12}$/.test(id) ? id : null;
  } catch {
    return null;
  }
}

/** Algolia item (story, comment, poll, job) with nested `children`. */
interface AlgoliaItem {
  id: number;
  type?: string;
  author?: string | null;
  title?: string | null;
  url?: string | null;
  text?: string | null;
  points?: number | null;
  created_at?: string | null;
  story_id?: number | null;
  children?: AlgoliaItem[];
}

const itemUrl = (id: number | string) => `https://news.ycombinator.com/item?id=${id}`;
/** HN text is HTML whose first paragraph has no `<p>`. */
const bodyHtml = (text: string | null | undefined) => (text?.trim() ? `<p>${text}` : "");

function toComment(c: AlgoliaItem, opAuthor: string | null, out: { n: number }): ThreadComment | null {
  if (out.n >= MAX_COMMENTS) return null;
  out.n++;
  const deleted = !c.author || !c.text?.trim();
  const node: ThreadComment = {
    id: String(c.id),
    author: c.author ?? null,
    score: null,
    created: c.created_at ?? null,
    permalink: itemUrl(c.id),
    bodyHtml: deleted ? "" : bodyHtml(c.text),
    deleted,
    op: !!opAuthor && c.author === opAuthor,
    children: [],
    more: 0,
  };
  for (const k of c.children ?? []) {
    const child = toComment(k, opAuthor, out);
    if (child) node.children.push(child);
  }
  return node;
}

const countTree = (cs: AlgoliaItem[]): number => cs.reduce((n, c) => n + (c.author && c.text ? 1 : 0) + countTree(c.children ?? []), 0);

/** Path of items from a top-level comment down to `id`, or null. */
function pathTo(items: AlgoliaItem[], id: number): AlgoliaItem[] | null {
  for (const it of items) {
    if (it.id === id) return [it];
    const p = pathTo(it.children ?? [], id);
    if (p) return [it, ...p];
  }
  return null;
}

/** Build the thread; `focusId` = the saved comment (its parents chain only), `rank` = top-level comment order. */
export function hnThread(story: AlgoliaItem, focusId: number | null, rank: number[] = []): Thread | null {
  if (!story || typeof story.id !== "number") return null;
  let top = [...(story.children ?? [])];
  if (rank.length) {
    const pos = new Map(rank.map((id, i) => [id, i]));
    top.sort((a, b) => (pos.get(a.id) ?? Number.MAX_SAFE_INTEGER) - (pos.get(b.id) ?? Number.MAX_SAFE_INTEGER));
  }
  if (focusId !== null && focusId !== story.id) {
    const path = pathTo(top, focusId);
    if (path) {
      // Keep only the chain: each parent with just the child on the path; the focus keeps its replies.
      const chain = path.map((it, i) => (i < path.length - 1 ? { ...it, children: [] as AlgoliaItem[] } : it));
      for (let i = chain.length - 2; i >= 0; i--) chain[i]!.children = [chain[i + 1]!];
      top = [chain[0]!];
    }
  }
  const out = { n: 0 };
  const comments = top.map((c) => toComment(c, story.author ?? null, out)).filter((c): c is ThreadComment => !!c);
  let link: string | null = null;
  try {
    link = story.url ? new URL(story.url).href : null;
  } catch {
    link = null;
  }
  const post: ThreadPost = {
    title: story.title ?? null,
    author: story.author ?? null,
    sub: null,
    flair: null,
    score: story.points ?? null,
    comments: countTree(story.children ?? []),
    created: story.created_at ?? null,
    permalink: itemUrl(story.id),
    bodyHtml: bodyHtml(story.text),
    images: [],
    link,
    video: false,
  };
  return { post, comments, more: 0, focusId: focusId !== null && focusId !== story.id ? String(focusId) : null };
}

async function getJson(url: string, opts: SafeFetchOptions, maxBytes?: number): Promise<unknown> {
  const res = await safeFetch(url, { ...opts, allow: ["other", "html"], accept: "application/json", ...(maxBytes ? { maxBytes } : {}) });
  return JSON.parse(new TextDecoder().decode(res.bytes));
}

/**
 * Fetch and render the story (with comments) behind a Hacker News item URL. Returns null when the URL isn't an
 * item or Algolia doesn't have it (callers then fall back to the page itself, which HN serves plainly).
 */
export async function extractHackerNews(url: string, opts: SafeFetchOptions = {}): Promise<Extracted | null> {
  const id = hnItemId(url);
  if (!id) return null;
  try {
    let item = (await getJson(`${ALGOLIA_ITEM}${id}`, opts, MAX_JSON_BYTES)) as AlgoliaItem | null;
    if (!item || typeof item.id !== "number") return null;
    const focus = item.type === "comment" ? item.id : null;
    if (focus !== null) {
      if (typeof item.story_id !== "number") return null;
      item = (await getJson(`${ALGOLIA_ITEM}${item.story_id}`, opts, MAX_JSON_BYTES)) as AlgoliaItem | null;
      if (!item || typeof item.id !== "number") return null;
    }
    let rank: number[] = [];
    try {
      const fb = (await getJson(`${FIREBASE_ITEM}${item.id}.json`, opts)) as { kids?: unknown } | null;
      if (Array.isArray(fb?.kids)) rank = fb.kids.filter((k): k is number => typeof k === "number");
    } catch (e) {
      if (!(e instanceof FetchError) && !(e instanceof SyntaxError)) throw e;
    }
    const th = hnThread(item, focus, rank);
    return th && renderThread(th, HN, "en", null);
  } catch (e) {
    if (!(e instanceof FetchError) && !(e instanceof SyntaxError)) throw e;
    return null;
  }
}
