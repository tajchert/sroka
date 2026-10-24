import type { Extracted } from "./extract.ts";
import { normalizeText } from "./extract.ts";
import { FetchError, safeFetch, type SafeFetchOptions } from "./safe-fetch.ts";

/**
 * X / Twitter posts. The x.com page is a JS app (servers get an empty shell, captures get a timeline full of UI
 * chrome), so read the post as JSON instead and build the article ourselves:
 * - FxTwitter `api.fxtwitter.com/2/thread/{id}`: the post, the author's whole self-reply thread (also when a middle
 *   post was saved), the parent chain of a reply, quotes, media, polls, link cards, community notes, X Articles.
 * - Fallback: X's own embed JSON (`cdn.syndication.twimg.com/tweet-result`): the single post + quote + parent.
 * Rendering: author header with date once per author run, the thread as continuous paragraphs, posts by other
 * authors (reply context) and quoted posts as blockquotes, photos / video posters as figures.
 */

const FX_API = "https://api.fxtwitter.com/2/thread/";
const SYNDICATION_API = "https://cdn.syndication.twimg.com/tweet-result";
const MAX_TWEETS = 120;
const MAX_QUOTE_DEPTH = 2;

export interface TweetRef {
  id: string;
  /** Handle from the URL (`/i/status/…` has none). */
  user: string | null;
}

const TWEET_HOST = /^(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com$/i;
const TWEET_PATH = /^\/(?:([A-Za-z0-9_]{1,15})|i(?:\/web)?)\/status(?:es)?\/(\d{1,25})(?:\/|$)/;

/** The post id of an X / Twitter status URL, or null. */
export function tweetRef(url: string): TweetRef | null {
  try {
    const u = new URL(url);
    if (!TWEET_HOST.test(u.hostname)) return null;
    const m = TWEET_PATH.exec(u.pathname);
    if (!m) return null;
    return { id: m[2]!, user: m[1] && m[1] !== "i" ? m[1] : null };
  } catch {
    return null;
  }
}

// ---- normalized model -------------------------------------------------------------------------------------

interface Media {
  kind: "photo" | "video" | "gif";
  /** Photo URL, or the video / GIF poster image. */
  src: string | null;
  alt: string | null;
  durationSec: number | null;
}

interface Card {
  url: string;
  title: string | null;
  description: string | null;
  domain: string | null;
}

interface Poll {
  choices: { label: string; percentage: number }[];
  totalVotes: number | null;
  endsAt: string | null;
}

export interface Tweet {
  id: string;
  url: string;
  name: string;
  handle: string;
  /** ISO 8601. */
  createdAt: string | null;
  lang: string | null;
  /** Raw text (t.co links still in it, HTML entities decoded). */
  text: string;
  /** t.co URL -> expanded link. */
  links: Map<string, { href: string; display: string }>;
  /** t.co URLs to drop from the text (media / quote / article links). */
  drop: Set<string>;
  media: Media[];
  quote: Tweet | { unavailable: string; url: string | null } | null;
  /** Handle this post replies to (null when not a reply). */
  replyingTo: string | null;
  poll: Poll | null;
  card: Card | null;
  communityNote: string | null;
  /** Rendered X Article body (already HTML) + its title / cover. */
  article: { title: string | null; cover: string | null; html: string; text: string } | null;
  likes: number | null;
  reposts: number | null;
  replies: number | null;
  views: number | null;
}

// ---- loose JSON access --------------------------------------------------------------------------------------

type J = Record<string, unknown>;
const obj = (v: unknown): J | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as J) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : null);

/** Twitter's legacy text fields keep `&amp;` / `&lt;` / `&gt;` escaped. */
const unescapeEntities = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

function isoFrom(seconds: number | null, text: string | null): string | null {
  const d = seconds !== null ? new Date(seconds * 1000) : text ? new Date(text) : null;
  return d && !Number.isNaN(d.getTime()) ? d.toISOString() : null;
}

/** Photo URL at a reader-friendly size (`name=orig` can be a 4096 px PNG). */
function photoUrl(u: string): string {
  try {
    const x = new URL(u);
    if (x.hostname !== "pbs.twimg.com" || !x.pathname.startsWith("/media/")) return u;
    const ext = /\.(jpe?g|png|webp)$/i.exec(x.pathname)?.[1];
    if (ext) {
      x.pathname = x.pathname.replace(/\.(jpe?g|png|webp)$/i, "");
      x.search = `?format=${ext.toLowerCase() === "jpeg" ? "jpg" : ext.toLowerCase()}&name=large`;
    } else {
      x.searchParams.set("name", "large");
    }
    return x.href;
  } catch {
    return u;
  }
}

function emptyTweet(id: string, handle: string, name: string): Tweet {
  return {
    id,
    url: `https://x.com/${handle || "i"}/status/${id}`,
    name,
    handle,
    createdAt: null,
    lang: null,
    text: "",
    links: new Map(),
    drop: new Set(),
    media: [],
    quote: null,
    replyingTo: null,
    poll: null,
    card: null,
    communityNote: null,
    article: null,
    likes: null,
    reposts: null,
    replies: null,
    views: null,
  };
}

// ---- FxTwitter API v2 ---------------------------------------------------------------------------------------

function fxMedia(container: J | null): Media[] {
  const out: Media[] = [];
  for (const raw of arr(container?.["all"])) {
    const m = obj(raw);
    const type = str(m?.["type"]);
    if (!m || !type) continue;
    if (type === "photo") {
      const url = str(m["url"]);
      if (url) out.push({ kind: "photo", src: photoUrl(url), alt: str(m["altText"]), durationSec: null });
    } else if (type === "video" || type === "gif") {
      out.push({ kind: type, src: str(m["thumbnail_url"]), alt: str(m["altText"]), durationSec: num(m["duration"]) });
    }
  }
  return out;
}

function fxTweet(raw: unknown, depth = 0): Tweet | null {
  const s = obj(raw);
  const id = str(s?.["id"]);
  if (!s || !id || s["type"] === "tombstone") return null;
  const author = obj(s["author"]);
  const handle = str(author?.["screen_name"]) ?? "i";
  const t = emptyTweet(id, handle, str(author?.["name"]) ?? handle);
  t.url = str(s["url"]) ?? t.url;
  t.createdAt = isoFrom(num(s["created_timestamp"]), str(s["created_at"]));
  t.lang = str(s["lang"]);
  const rawText = obj(s["raw_text"]);
  t.text = unescapeEntities(str(rawText?.["text"]) ?? str(s["text"]) ?? "");
  for (const f of arr(rawText?.["facets"])) {
    const facet = obj(f);
    const original = str(facet?.["original"]);
    if (!facet || !original) continue;
    if (facet["type"] === "url") {
      const href = str(facet["replacement"]) ?? original;
      t.links.set(original, { href, display: str(facet["display"]) ?? href });
    } else if (facet["type"] === "media") {
      t.drop.add(original);
    }
  }
  t.media = fxMedia(obj(s["media"]));
  t.replyingTo = str(obj(s["replying_to"])?.["screen_name"]);
  t.likes = num(s["likes"]);
  t.reposts = num(s["reposts"]) ?? num(s["retweets"]);
  t.replies = num(s["replies"]);
  t.views = num(s["views"]);
  t.communityNote = str(obj(s["community_note"])?.["text"]);

  const poll = obj(s["poll"]);
  if (poll) {
    const choices = arr(poll["choices"])
      .map(obj)
      .filter((c): c is J => !!c && !!str(c["label"]))
      .map((c) => ({ label: str(c["label"])!, percentage: num(c["percentage"]) ?? 0 }));
    if (choices.length) t.poll = { choices, totalVotes: num(poll["total_votes"]), endsAt: str(poll["ends_at"]) };
  }
  const card = obj(s["card"]);
  const cardUrl = str(card?.["url"]);
  if (card && cardUrl) t.card = { url: cardUrl, title: str(card["title"]), description: str(card["description"]), domain: str(card["domain"]) };

  const quote = obj(s["quote"]);
  if (quote) {
    if (quote["type"] === "tombstone") {
      t.quote = { unavailable: str(quote["message"]) ?? "This post is unavailable.", url: str(quote["url"]) };
    } else if (depth < MAX_QUOTE_DEPTH) {
      t.quote = fxTweet(quote, depth + 1);
    } else {
      t.quote = { unavailable: "", url: str(quote["url"]) };
    }
    // The quoted post's permalink is usually left at the end of the text.
    const qid = str(quote["id"]);
    for (const [tco, link] of t.links) if (qid && link.href.includes(`/status/${qid}`)) t.drop.add(tco);
  }

  const article = obj(s["article"]);
  if (article) {
    t.article = renderArticle(article);
    // The post text of an article is just its link.
    for (const [tco, link] of t.links) if (/\/(i\/)?article\//.test(link.href)) t.drop.add(tco);
  }
  return t;
}

/** Parse an FxTwitter `/2/thread` response: the posts in order and the id of the saved one. */
export function parseFxThread(json: unknown): { tweets: Tweet[]; focusId: string } | null {
  const root = obj(json);
  const status = obj(root?.["status"]);
  const focus = fxTweet(status);
  if (!root || !focus) return null;
  const tweets = arr(root["thread"])
    .slice(0, MAX_TWEETS)
    .map((x) => fxTweet(x))
    .filter((x): x is Tweet => !!x);
  if (!tweets.some((t) => t.id === focus.id)) tweets.push(focus);
  else {
    // The `status` entry is the richest copy (thread entries may omit fields such as the article body).
    const i = tweets.findIndex((t) => t.id === focus.id);
    if (focus.article && !tweets[i]!.article) tweets[i] = focus;
  }
  return { tweets, focusId: focus.id };
}

// ---- X Articles (Draft.js content_state) --------------------------------------------------------------------

function articleMediaUrl(article: J, mediaId: string): string | null {
  for (const raw of [obj(article["cover_media"]), ...arr(article["media_entities"]).map(obj)]) {
    if (!raw || (str(raw["media_id"]) !== mediaId && str(raw["id"]) !== mediaId)) continue;
    const info = obj(raw["media_info"]);
    return str(info?.["original_img_url"]) ?? str(info?.["media_url_https"]);
  }
  return null;
}

/** Inline styles + LINK entities of one Draft.js block -> HTML. Offsets are UTF-16 indices (JS string). */
function inlineHtml(text: string, block: J, entities: Map<string, J>): string {
  const n = text.length;
  const bold = new Uint8Array(n);
  const italic = new Uint8Array(n);
  const strike = new Uint8Array(n);
  const link: (string | null)[] = new Array(n).fill(null);
  for (const r of arr(block["inlineStyleRanges"])) {
    const range = obj(r);
    const off = num(range?.["offset"]) ?? 0;
    const len = num(range?.["length"]) ?? 0;
    const style = String(range?.["style"] ?? "").toLowerCase();
    const target = style === "bold" ? bold : style === "italic" ? italic : style === "strikethrough" ? strike : null;
    if (target) target.fill(1, off, Math.min(n, off + len));
  }
  for (const r of arr(block["entityRanges"])) {
    const range = obj(r);
    const ent = entities.get(String(range?.["key"]));
    const url = str(obj(ent?.["data"])?.["url"]);
    if (!ent || String(ent["type"]).toUpperCase() !== "LINK" || !url) continue;
    const off = num(range?.["offset"]) ?? 0;
    link.fill(url, off, Math.min(n, off + (num(range?.["length"]) ?? 0)));
  }
  let out = "";
  let i = 0;
  while (i < n) {
    let j = i + 1;
    while (j < n && bold[j] === bold[i] && italic[j] === italic[i] && strike[j] === strike[i] && link[j] === link[i]) j++;
    let seg = esc(text.slice(i, j)).replace(/\n/g, "<br>");
    if (strike[i]) seg = `<s>${seg}</s>`;
    if (italic[i]) seg = `<em>${seg}</em>`;
    if (bold[i]) seg = `<strong>${seg}</strong>`;
    if (link[i]) seg = `<a href="${esc(link[i]!)}">${seg}</a>`;
    out += seg;
    i = j;
  }
  return out;
}

function renderArticle(article: J): { title: string | null; cover: string | null; html: string; text: string } | null {
  const content = obj(article["content"]);
  const entities = new Map<string, J>();
  for (const e of arr(content?.["entityMap"])) {
    const entry = obj(e);
    const value = obj(entry?.["value"]);
    if (entry && value) entities.set(String(entry["key"]), value);
  }
  const parts: string[] = [];
  const text: string[] = [];
  const open: { list: { tag: "ul" | "ol"; items: string[] } | null } = { list: null };
  const flush = () => {
    const l = open.list;
    if (l) parts.push(`<${l.tag}>${l.items.map((i) => `<li>${i}</li>`).join("")}</${l.tag}>`);
    open.list = null;
  };
  for (const b of arr(content?.["blocks"])) {
    const block = obj(b);
    if (!block) continue;
    const type = str(block["type"]) ?? "unstyled";
    const raw = typeof block["text"] === "string" ? block["text"] : "";
    if (type === "unordered-list-item" || type === "ordered-list-item") {
      const tag = type === "unordered-list-item" ? "ul" : "ol";
      if (open.list?.tag !== tag) flush();
      open.list ??= { tag, items: [] };
      open.list.items.push(inlineHtml(raw, block, entities));
      text.push(raw);
      continue;
    }
    flush();
    if (type === "atomic") {
      for (const r of arr(block["entityRanges"])) {
        const ent = entities.get(String(obj(r)?.["key"]));
        const data = obj(ent?.["data"]);
        const kind = String(ent?.["type"] ?? "").toUpperCase();
        if (kind === "MEDIA") {
          for (const item of arr(data?.["mediaItems"])) {
            const src = articleMediaUrl(article, str(obj(item)?.["mediaId"]) ?? "");
            if (src) parts.push(`<figure><img src="${esc(src)}" alt=""></figure>`);
          }
        } else if (kind === "TWEET" && str(data?.["tweetId"])) {
          const href = `https://x.com/i/status/${str(data!["tweetId"])}`;
          parts.push(`<p><a href="${esc(href)}">Embedded post</a></p>`);
        } else if (kind === "MARKDOWN" && str(data?.["markdown"])) {
          const md = str(data!["markdown"])!;
          const fence = /^```[^\n]*\n([\s\S]*?)\n?```\s*$/.exec(md);
          parts.push(`<pre><code>${esc(fence ? fence[1]! : md)}</code></pre>`);
          text.push(fence ? fence[1]! : md);
        }
      }
      continue;
    }
    if (!raw.trim()) continue;
    const inner = inlineHtml(raw, block, entities);
    text.push(raw);
    const tag =
      type === "header-one" ? "h2" : type === "header-two" ? "h3" : type === "header-three" ? "h4" : type === "blockquote" ? "blockquote" : type === "code-block" ? "pre" : "p";
    parts.push(`<${tag}>${inner}</${tag}>`);
  }
  flush();
  if (!parts.length) return null;
  const coverId = str(obj(article["cover_media"])?.["media_id"]);
  return {
    title: str(article["title"]),
    cover: coverId ? articleMediaUrl(article, coverId) : null,
    html: parts.join("\n"),
    text: text.join("\n\n"),
  };
}

// ---- X embed (syndication) JSON -----------------------------------------------------------------------------

/** Token the embed endpoint expects (same formula as react-tweet). */
export function syndicationToken(id: string): string {
  return ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
}

function syndicationTweet(raw: unknown, depth = 0): Tweet | null {
  const s = obj(raw);
  const id = str(s?.["id_str"]);
  if (!s || !id || s["__typename"] === "TweetTombstone") return null;
  const user = obj(s["user"]);
  const handle = str(user?.["screen_name"]) ?? "i";
  const t = emptyTweet(id, handle, str(user?.["name"]) ?? handle);
  t.createdAt = isoFrom(null, str(s["created_at"]));
  t.lang = str(s["lang"]);
  const note = str(obj(obj(obj(s["note_tweet"])?.["note_tweet_results"])?.["result"])?.["text"]);
  t.text = unescapeEntities(note ?? str(s["text"]) ?? "");
  const entities = obj(s["entities"]);
  for (const u of arr(entities?.["urls"])) {
    const e = obj(u);
    const tco = str(e?.["url"]);
    if (e && tco) t.links.set(tco, { href: str(e["expanded_url"]) ?? tco, display: str(e["display_url"]) ?? tco });
  }
  for (const m of arr(entities?.["media"])) {
    const tco = str(obj(m)?.["url"]);
    if (tco) t.drop.add(tco);
  }
  for (const raw of arr(s["mediaDetails"])) {
    const m = obj(raw);
    const type = str(m?.["type"]);
    const src = str(m?.["media_url_https"]);
    if (!m || !type) continue;
    const alt = str(m["ext_alt_text"]);
    if (type === "photo" && src) t.media.push({ kind: "photo", src: photoUrl(src), alt, durationSec: null });
    else if (type === "video" || type === "animated_gif") {
      const ms = num(obj(m["video_info"])?.["duration_millis"]);
      t.media.push({ kind: type === "video" ? "video" : "gif", src, alt, durationSec: ms !== null ? ms / 1000 : null });
    }
  }
  t.replyingTo = str(s["in_reply_to_screen_name"]);
  t.likes = num(s["favorite_count"]);
  t.replies = num(s["conversation_count"]);
  const quoted = s["quoted_tweet"];
  if (quoted && depth < MAX_QUOTE_DEPTH) {
    t.quote = syndicationTweet(quoted, depth + 1) ?? { unavailable: "This post is unavailable.", url: null };
    const qid = str(obj(quoted)?.["id_str"]);
    for (const [tco, link] of t.links) if (qid && link.href.includes(`/status/${qid}`)) t.drop.add(tco);
  }
  const card = obj(s["card"]);
  const values = obj(card?.["binding_values"]);
  const cardUrl = str(card?.["url"]);
  const cardTitle = str(obj(values?.["title"])?.["string_value"]);
  if (cardUrl && cardTitle && !(str(card?.["name"]) ?? "").startsWith("poll")) {
    t.card = {
      url: t.links.get(cardUrl)?.href ?? cardUrl,
      title: cardTitle,
      description: str(obj(values?.["description"])?.["string_value"]),
      domain: str(obj(values?.["domain"])?.["string_value"]) ?? str(obj(values?.["vanity_url"])?.["string_value"]),
    };
  }
  return t;
}

/** Parse an embed (syndication) response: optional parent, then the post. */
export function parseSyndication(json: unknown): { tweets: Tweet[]; focusId: string } | null {
  const focus = syndicationTweet(json);
  if (!focus) return null;
  const parent = syndicationTweet(obj(json)?.["parent"]);
  return { tweets: parent ? [parent, focus] : [focus], focusId: focus.id };
}

// ---- rendering ----------------------------------------------------------------------------------------------

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const fmtCount = (n: number) => n.toLocaleString("en-US");
const plural = (n: number, one: string, many = `${one}s`) => `${fmtCount(n)} ${n === 1 ? one : many}`;

export function formatTweetDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const date = d.toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const time = d.toLocaleString("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" });
  return `${date}, ${time} UTC`;
}

function duration(sec: number): string {
  const s = Math.round(sec);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}

/** Text with @mentions / #hashtags / $cashtags linked (input is plain text; output is escaped HTML). */
function linkifyPlain(s: string): string {
  const re = /(^|[^\p{L}\p{N}_&/])([@#$])([\p{L}\p{N}_]{1,50})/gu;
  let out = "";
  let last = 0;
  for (const m of s.matchAll(re)) {
    const [whole, pre, sigil, word] = m as unknown as [string, string, string, string];
    const at = m.index! + pre.length;
    if (sigil === "@" && !/^[A-Za-z0-9_]{1,15}$/.test(word)) continue;
    if (sigil === "$" && !/^[A-Za-z]{1,6}$/.test(word)) continue;
    if (sigil === "#" && /^\d+$/.test(word)) continue;
    const href =
      sigil === "@" ? `https://x.com/${word}` : `https://x.com/search?q=${encodeURIComponent(sigil + word)}`;
    out += esc(s.slice(last, at)) + `<a href="${esc(href)}">${esc(sigil + word)}</a>`;
    last = m.index! + whole.length;
  }
  return out + esc(s.slice(last));
}

/** Post text -> paragraphs: t.co links expanded (or dropped), mentions/hashtags linked, line breaks kept. */
function textHtml(t: Tweet, stripReplyMentions: boolean): { html: string; text: string } {
  let raw = t.text;
  if (stripReplyMentions) raw = raw.replace(/^(?:@[A-Za-z0-9_]{1,15}\s+)+/, "");
  const parts: string[] = [];
  const plain: string[] = [];
  let last = 0;
  for (const m of raw.matchAll(/https?:\/\/t\.co\/[A-Za-z0-9]+/g)) {
    const before = raw.slice(last, m.index);
    parts.push(linkifyPlain(before));
    plain.push(before);
    last = m.index! + m[0].length;
    if (t.drop.has(m[0])) continue;
    const link = t.links.get(m[0]);
    const href = link?.href ?? m[0];
    const display = link?.display ?? m[0];
    parts.push(`<a href="${esc(href)}">${esc(display)}</a>`);
    plain.push(display);
  }
  parts.push(linkifyPlain(raw.slice(last)));
  plain.push(raw.slice(last));
  const html = parts
    .join("")
    .trim()
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`)
    .join("\n");
  return { html, text: normalizeText(plain.join("")) };
}

function mediaHtml(t: Tweet): string {
  return t.media
    .map((m) => {
      const img = m.src ? `<img src="${esc(m.src)}" alt="${esc(m.alt ?? "")}">` : "";
      if (m.kind === "photo") return img ? `<figure>${img}${m.alt ? `<figcaption>${esc(m.alt)}</figcaption>` : ""}</figure>` : "";
      const label = m.kind === "gif" ? "GIF" : `Video${m.durationSec ? ` · ${duration(m.durationSec)}` : ""}`;
      return `<figure>${img ? `<a href="${esc(t.url)}">${img}</a>` : ""}<figcaption>▶ ${label} — <a href="${esc(t.url)}">watch on X</a></figcaption></figure>`;
    })
    .filter(Boolean)
    .join("\n");
}

function pollHtml(p: Poll): string {
  const items = p.choices.map((c) => `<li>${esc(c.label)} — ${Math.round(c.percentage * 10) / 10}%</li>`).join("");
  const ended = p.endsAt && new Date(p.endsAt).getTime() < Date.now();
  const meta = [p.totalVotes !== null ? plural(p.totalVotes, "vote") : null, ended ? "final results" : p.endsAt ? `ends ${formatTweetDate(p.endsAt)}` : null]
    .filter(Boolean)
    .join(" · ");
  return `<ul>${items}</ul>${meta ? `<p><small>Poll · ${esc(meta)}</small></p>` : ""}`;
}

function headerHtml(t: Tweet, extra?: string): string {
  const date = t.createdAt ? ` · <a href="${esc(t.url)}"><time datetime="${esc(t.createdAt)}">${esc(formatTweetDate(t.createdAt))}</time></a>` : "";
  const who = `<strong>${esc(t.name)}</strong> <a href="https://x.com/${esc(t.handle)}">@${esc(t.handle)}</a>`;
  return `<p><small>${extra ? `${esc(extra)} ` : ""}${who}${date}</small></p>`;
}

interface Rendered {
  html: string;
  text: string[];
}

/** One post's body (no header): reply note, text or article, media, poll, card, quote, community note. */
function bodyHtml(t: Tweet, prevHandle: string | null, depth: number, out: Rendered): string {
  const parts: string[] = [];
  const isReply = !!t.replyingTo;
  if (isReply && t.replyingTo!.toLowerCase() !== (prevHandle ?? "").toLowerCase() && t.replyingTo!.toLowerCase() !== t.handle.toLowerCase()) {
    parts.push(`<p><small>Replying to <a href="https://x.com/${esc(t.replyingTo!)}">@${esc(t.replyingTo!)}</a></small></p>`);
  }
  const body = textHtml(t, isReply);
  if (body.html) parts.push(body.html);
  if (body.text) out.text.push(body.text);
  if (t.article) {
    if (t.article.title) parts.push(`<h2>${esc(t.article.title)}</h2>`);
    if (t.article.cover) parts.push(`<figure><img src="${esc(t.article.cover)}" alt=""></figure>`);
    parts.push(t.article.html);
    out.text.push(t.article.title ?? "", t.article.text);
  }
  const media = mediaHtml(t);
  if (media) parts.push(media);
  if (t.poll) {
    parts.push(pollHtml(t.poll));
    out.text.push(t.poll.choices.map((c) => c.label).join("\n"));
  }
  if (t.card && !t.media.length && !t.quote) {
    const host = t.card.domain ?? (() => { try { return new URL(t.card!.url).hostname; } catch { return null; } })();
    const sub = [host, t.card.description].filter(Boolean).join(" — ");
    parts.push(`<p><a href="${esc(t.card.url)}">${esc(t.card.title ?? t.card.url)}</a>${sub ? `<br><small>${esc(sub)}</small>` : ""}</p>`);
  }
  if (t.quote) {
    if ("unavailable" in t.quote) {
      const link = t.quote.url ? ` <a href="${esc(t.quote.url)}">View on X</a>` : "";
      parts.push(`<blockquote><p><small>${esc(t.quote.unavailable || "Quoted post")}${link}</small></p></blockquote>`);
    } else {
      parts.push(`<blockquote>${headerHtml(t.quote)}${bodyHtml(t.quote, null, depth + 1, out)}</blockquote>`);
    }
  }
  if (t.communityNote) {
    parts.push(`<blockquote><p><small><strong>Community note</strong></small></p><p>${esc(t.communityNote)}</p></blockquote>`);
    out.text.push(t.communityNote);
  }
  return parts.join("\n");
}

function titleFrom(t: Tweet): string {
  if (t.article?.title) return t.article.title;
  const plain = textHtml(t, !!t.replyingTo).text.replace(/https?:\/\/\S+/g, "").trim();
  const first = plain.split("\n").find((l) => l.trim())?.trim() ?? "";
  if (!first) return `${t.name} on X`;
  if (first.length <= 110) return first;
  const cut = first.slice(0, 110);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), 80)).replace(/[\s,.;:–—-]+$/, "")}…`;
}

/**
 * Build the article: posts before the saved post's author run (a reply's parents) as quoted context, then the
 * author's run(s) as continuous text with one header per run, then a stats footer.
 */
export function renderTweets(tweets: Tweet[], focusId: string): Extracted | null {
  const focus = tweets.find((t) => t.id === focusId) ?? tweets[0];
  if (!focus) return null;
  const author = focus.handle.toLowerCase();
  // The first post of the author run that contains the saved post (= the thread's first post).
  const fi = tweets.indexOf(focus);
  let start = fi;
  while (start > 0 && tweets[start - 1]!.handle.toLowerCase() === author) start--;
  const main = tweets[start]!;
  let end = fi;
  while (end + 1 < tweets.length && tweets[end + 1]!.handle.toLowerCase() === author) end++;

  const out: Rendered = { html: "", text: [] };
  const parts: string[] = [];
  // Context: the conversation the thread replies to.
  let prev: string | null = null;
  for (const t of tweets.slice(0, start)) {
    parts.push(`<blockquote>${headerHtml(t)}${bodyHtml(t, prev, 1, out)}</blockquote>`);
    prev = t.handle;
  }
  parts.push(headerHtml(main));
  for (const t of tweets.slice(start, end + 1)) {
    parts.push(bodyHtml(t, prev, 0, out));
    prev = t.handle;
  }
  // Anything after the run (rare: replies by others included by the API) keeps its own headers.
  for (const t of tweets.slice(end + 1)) {
    parts.push(`<hr>${headerHtml(t)}${bodyHtml(t, prev, 0, out)}`);
    prev = t.handle;
  }
  const count = end - start + 1;
  const stats = [
    count > 1 ? `Thread · ${plural(count, "post")}` : null,
    main.replies ? plural(main.replies, "reply", "replies") : null,
    main.reposts ? plural(main.reposts, "repost") : null,
    main.likes ? plural(main.likes, "like") : null,
    main.views ? plural(main.views, "view") : null,
  ].filter(Boolean);
  parts.push(`<hr>\n<p><small>${stats.map((s) => esc(s!)).join(" · ")}${stats.length ? " · " : ""}<a href="${esc(main.url)}">View on X</a></small></p>`);

  const text = normalizeText(out.text.filter(Boolean).join("\n\n"));
  if (!text && !tweets.some((t) => t.media.length)) return null;
  const ownMedia = tweets.slice(start, end + 1).flatMap((t) => [t.article?.cover ?? null, ...t.media.map((m) => m.src)]);
  return {
    title: titleFrom(main),
    byline: `${main.name} (@${main.handle})`,
    siteName: "X",
    lang: main.lang && main.lang !== "zxx" && main.lang !== "und" ? main.lang : null,
    publishedTime: main.createdAt,
    excerpt: textHtml(main, !!main.replyingTo).text.slice(0, 300) || null,
    contentHtml: parts.join("\n"),
    text: text || titleFrom(main),
    leadImage: ownMedia.find((u): u is string => !!u) ?? null,
  };
}

// ---- fetching -----------------------------------------------------------------------------------------------

async function getJson(url: string, opts: SafeFetchOptions): Promise<unknown> {
  const res = await safeFetch(url, { ...opts, allow: ["other", "html"], accept: "application/json" });
  return JSON.parse(new TextDecoder().decode(res.bytes));
}

/**
 * Fetch and render the post (and thread) behind an X / Twitter status URL. Returns null when the URL isn't a post
 * or neither API has it (deleted, protected, API down): callers then fall back to the page itself.
 */
export async function extractTweet(url: string, opts: SafeFetchOptions = {}): Promise<Extracted | null> {
  const ref = tweetRef(url);
  if (!ref) return null;
  const sources: [string, (j: unknown) => { tweets: Tweet[]; focusId: string } | null][] = [
    [`${FX_API}${ref.id}`, parseFxThread],
    [`${SYNDICATION_API}?id=${ref.id}&token=${syndicationToken(ref.id)}&lang=en`, parseSyndication],
  ];
  for (const [api, parse] of sources) {
    try {
      const parsed = parse(await getJson(api, opts));
      const ex = parsed && renderTweets(parsed.tweets, parsed.focusId);
      if (ex) return ex;
    } catch (e) {
      if (!(e instanceof FetchError) && !(e instanceof SyntaxError)) throw e;
    }
  }
  return null;
}
