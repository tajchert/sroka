import { describe, expect, it } from "vitest";
import { extractHackerNews, hnItemId, hnThread } from "./hackernews.ts";
import { sanitizeArticle } from "./sanitize.ts";

const STORY_URL = "https://news.ycombinator.com/item?id=100";
type I = { id: number; author?: string | null; text?: string | null; children?: I[] };
const c = (id: number, children: I[] = [], extra: Partial<I> = {}): I => ({ id, author: `user${id}`, text: `Comment ${id} has enough words.<p>Second <a href="item?id=1">para</a>`, children, ...extra });
const node = (i: I, storyId = 100): unknown => ({
  id: i.id,
  type: "comment",
  author: i.author,
  text: i.text,
  points: null,
  created_at: "2026-10-22T12:00:00.000Z",
  story_id: storyId,
  children: (i.children ?? []).map((k) => node(k, storyId)),
});
const story = (children: I[], extra: Record<string, unknown> = {}) => ({
  id: 100,
  type: "story",
  author: "op",
  title: "How Japanese Dried Bonito Is Made",
  url: "https://kottke.org/26/10/how-japanese-dried-bonito-is-made",
  text: null,
  points: 124,
  created_at: "2026-10-22T11:31:03.000Z",
  story_id: 100,
  children: children.map((k) => node(k)),
  ...extra,
});
// 1 > 2 > 3 > 4 > 5 > 6 (6 levels); 7 posted by OP; 8 deleted with a reply 9; 10 deleted leaf
const tree = () => [c(1, [c(2, [c(3, [c(4, [c(5, [c(6)])])])])]), c(7, [], { author: "op" }), c(8, [c(9)], { author: null, text: null }), c(10, [], { author: null, text: null })];

const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const api = (items: Record<string, unknown>, kids?: number[]) =>
  (async (u: string) => {
    if (u.startsWith("https://hacker-news.firebaseio.com/")) return kids ? json({ id: 100, kids }) : new Response("down", { status: 503 });
    const id = /items\/(\d+)$/.exec(u)?.[1];
    return id && items[id] ? json(items[id]) : new Response("nf", { status: 404 });
  }) as unknown as typeof fetch;

describe("hnItemId", () => {
  it("accepts item URLs only", () => {
    expect(hnItemId(STORY_URL)).toBe("100");
    expect(hnItemId("https://news.ycombinator.com/item?id=50193936&p=2")).toBe("50193936");
    expect(hnItemId("https://news.ycombinator.com/news")).toBeNull();
    expect(hnItemId("https://news.ycombinator.com/item?id=abc")).toBeNull();
    expect(hnItemId("https://example.com/item?id=1")).toBeNull();
  });
});

describe("extractHackerNews", () => {
  it("renders the story card and ranked comments with 3 reply levels", async () => {
    const ex = (await extractHackerNews(STORY_URL, { fetch: api({ 100: story(tree()) }, [7, 1, 8, 10]) }))!;
    expect(ex.title).toBe("How Japanese Dried Bonito Is Made");
    expect(ex.siteName).toBe("Hacker News");
    expect(ex.byline).toBe("op");
    const h = ex.contentHtml;
    expect(h).toContain('<a href="https://kottke.org/26/10/how-japanese-dried-bonito-is-made">');
    expect(h).toContain("124 points · 8 comments");
    // HN ranking: 7 before 1
    expect(h.indexOf("Comment 7 has")).toBeLessThan(h.indexOf("Comment 1 has"));
    expect(h).toContain(" <small>OP</small>");
    for (const id of [1, 2, 3, 4]) expect(h).toContain(`Comment ${id} has`);
    expect(h).not.toContain("Comment 5 has");
    expect(h).toContain('<a href="https://news.ycombinator.com/item?id=4">2 more replies on Hacker News</a>');
    // deleted parent kept as placeholder for its reply, deleted leaf dropped
    expect(h).toMatch(/\[deleted\][^]*Comment 9 has/);
    expect(h).toContain("8 comments · View all on Hacker News");
    expect(h).toContain('<a href="https://news.ycombinator.com/user?id=user1">user1</a>');
    const san = sanitizeArticle(h, STORY_URL);
    expect(san.html).toContain('href="https://news.ycombinator.com/item?id=1"');
    expect(san.html).toContain('<div class="sr-replies">');
  });

  it("a comment link shows its parents, the comment highlighted and its replies", async () => {
    const items = { 100: story(tree()), 3: node(c(3, [c(4, [c(5, [c(6)])])])) };
    const ex = (await extractHackerNews("https://news.ycombinator.com/item?id=3", { fetch: api(items) }))!;
    const h = ex.contentHtml;
    expect(ex.title).toBe("How Japanese Dried Bonito Is Made");
    expect(ex.byline).toBe("user3");
    expect(ex.excerpt).toMatch(/^Comment 3 has enough words\./);
    expect(h).toContain('<div class="sr-reply sr-post-focus">');
    for (const id of [1, 2, 3, 4, 5, 6]) expect(h).toContain(`Comment ${id} has`);
    expect(h).not.toContain("Comment 7 has");
    expect(h).toContain("View all 8 comments on Hacker News");
  });

  it("keeps Ask HN text; null when the API has nothing", async () => {
    const ask = story([], { url: null, title: "Ask HN: Favourite tools?", text: "What do you use<p>daily?" });
    const ex = (await extractHackerNews(STORY_URL, { fetch: api({ 100: ask }) }))!;
    expect(ex.contentHtml).toContain("<p>What do you use<p>daily?");
    expect(ex.contentHtml).not.toContain("<h2>Comments</h2>");
    expect(await extractHackerNews(STORY_URL, { fetch: api({}) })).toBeNull();
    expect(await extractHackerNews("https://example.com/", { fetch: api({}) })).toBeNull();
  });

  it("hnThread ignores a focus id that isn't in the tree", () => {
    const th = hnThread(story(tree()) as never, 999)!;
    expect(th.focusId).toBe("999");
    expect(th.comments).toHaveLength(4);
  });
});
