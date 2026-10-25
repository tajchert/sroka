import { describe, expect, it } from "vitest";
import { detectBotWall } from "./bot-wall.ts";
import { extractArticle } from "./extract.ts";
import { extractReddit, isRedditUrl } from "./reddit.ts";
import { sanitizeArticle } from "./sanitize.ts";

const THREAD = "https://www.reddit.com/r/AskReddit/comments/1xcwkya/which_tv_series_has_a_1010_unskippable_theme_song/";

// Trimmed shape of a rendered shreddit thread (attributes and slots as Reddit serves them).
const threadHtml = `<!doctype html><html lang="en"><head><title>Which TV series has a 10/10 theme song? : r/AskReddit</title>
<meta property="og:image" content="https://share.redd.it/preview/post/1xcwkya"></head><body>
<shreddit-app>
<shreddit-post id="t3_1xcwkya" post-title="Which TV series has a 10/10 unskippable theme song?" author="songfan" subreddit-prefixed-name="r/AskReddit"
  score="5120" comment-count="3400" created-timestamp="2026-10-22T18:01:02.000000+0000" post-type="text"
  permalink="/r/AskReddit/comments/1xcwkya/which_tv_series_has_a_1010_unskippable_theme_song/" content-href="${THREAD}">
  <faceplate-tracker><img src="https://styles.redditmedia.com/t5_2qh1i/styles/communityIcon.png" alt="r/AskReddit icon"></faceplate-tracker>
  <h1 slot="title">Which TV series has a 10/10 unskippable theme song?</h1>
  <div slot="text-body"><div class="md"><p>Looking for intros you never skip.</p></div></div>
</shreddit-post>
<shreddit-comment-tree>
  <shreddit-comment thingid="t1_a" author="alice" score="900" depth="0">
    <div slot="comment" id="t1_a-comment-rtjson-content"><p>Game of Thrones. Every single time.</p></div>
    <shreddit-comment thingid="t1_b" author="bob" score="120" depth="1" parentid="t1_a">
      <div slot="comment"><p>The map sequence alone!</p></div>
      <shreddit-comment thingid="t1_c" author="[deleted]" depth="2" is-comment-deleted="">
        <div slot="comment"><p>[deleted]</p></div>
        <shreddit-comment thingid="t1_d" author="carol" score="1" depth="3"><div slot="comment"><p>Agreed.</p></div></shreddit-comment>
      </shreddit-comment>
    </shreddit-comment>
  </shreddit-comment>
  <shreddit-comment thingid="t1_e" author="dave" score="450" depth="0"><div slot="comment"><p>Cowboy Bebop. <a href="/r/cowboybebop">r/cowboybebop</a></p></div></shreddit-comment>
  <shreddit-comment thingid="t1_f" author="[deleted]" depth="0" is-comment-deleted=""><div slot="comment"><p>[removed]</p></div></shreddit-comment>
</shreddit-comment-tree>
</shreddit-app></body></html>`;

describe("extractReddit", () => {
  it("recognises reddit hosts only", () => {
    expect(isRedditUrl(THREAD)).toBe(true);
    expect(isRedditUrl("https://old.reddit.com/r/x")).toBe(true);
    expect(isRedditUrl("https://notreddit.com/x")).toBe(false);
    expect(extractReddit(threadHtml, "https://example.com/r/x/comments/1")).toBeNull();
  });

  it("builds post + nested comments from a rendered thread", () => {
    const ex = extractReddit(threadHtml, THREAD)!;
    expect(ex.title).toBe("Which TV series has a 10/10 unskippable theme song?");
    expect(ex.byline).toBe("u/songfan in r/AskReddit");
    expect(ex.siteName).toBe("Reddit");
    expect(ex.publishedTime).toBe("2026-10-22T18:01:02.000000+0000");
    expect(ex.excerpt).toBe("Looking for intros you never skip.");
    expect(ex.contentHtml).toContain("<strong>r/AskReddit</strong>");
    expect(ex.contentHtml).toContain("5,120 points · 3,400 comments");
    expect(ex.contentHtml).toContain("<h2>Comments</h2>");
    // reply nesting: bob inside alice, carol kept under a [deleted] placeholder
    expect(ex.contentHtml).toMatch(/<div class="sr-post">[^]*u\/alice[^]*<div class="sr-replies"><div class="sr-reply">[^]*u\/bob[^]*\[deleted\][^]*u\/carol/);
    // a deleted leaf comment is dropped entirely; community icon is not a post image
    expect(ex.contentHtml).not.toContain("[removed]");
    expect(ex.contentHtml).not.toContain("communityIcon");
    expect(ex.text).toContain("Cowboy Bebop.");
    expect(ex.text).toContain("Game of Thrones. Every single time.");
  });

  it("survives sanitizing (relative links absolutized)", () => {
    const ex = extractReddit(threadHtml, THREAD)!;
    const san = sanitizeArticle(ex.contentHtml, THREAD);
    expect(san.html).toContain('href="https://www.reddit.com/r/cowboybebop"');
    expect(san.html).toContain('<div class="sr-replies">');
    expect(san.html).toContain('<div class="sr-reply">');
  });

  it("is used by extractArticle ahead of Readability", () => {
    expect(extractArticle(threadHtml, THREAD)?.contentHtml).toContain("u/dave");
  });

  it("keeps image posts and external links", () => {
    const html = `<html><body><shreddit-post post-title="Look at this" author="x" subreddit-prefixed-name="r/pics" post-type="gallery" content-href="https://example.org/story">
      <gallery-carousel><li><img src="https://preview.redd.it/a.jpg?width=640&amp;s=1"></li><li><img src="https://preview.redd.it/a.jpg?width=320"></li><li><img src="https://i.redd.it/b.png"></li></gallery-carousel>
      </shreddit-post><shreddit-comment author="y" score="3"><div slot="comment"><p>Nice picture, really.</p></div></shreddit-comment></body></html>`;
    const ex = extractReddit(html, "https://www.reddit.com/r/pics/comments/abc/look/")!;
    expect(ex.contentHtml.match(/<img /g)).toHaveLength(2);
    expect(ex.leadImage).toBe("https://preview.redd.it/a.jpg?width=640&s=1");
    expect(ex.contentHtml).toContain('<a href="https://example.org/story">');
  });

  it("turns a listing page into a list of posts", () => {
    const html = `<html><head><title>Reddit - The heart of the internet</title></head><body>
      <shreddit-post post-title="First" permalink="/r/a/comments/1/first/" subreddit-prefixed-name="r/a" score="10" comment-count="2"></shreddit-post>
      <shreddit-post post-title="Second" permalink="/r/b/comments/2/second/" subreddit-prefixed-name="r/b"></shreddit-post></body></html>`;
    const ex = extractReddit(html, "https://www.reddit.com/")!;
    expect(ex.title).toBe("Reddit - The heart of the internet");
    expect(ex.contentHtml).toContain('<a href="https://www.reddit.com/r/a/comments/1/first/">First</a>');
    expect(ex.contentHtml).toContain("r/a · 10 points · 2 comments");
  });

  it("returns null without shreddit markup", () => {
    expect(extractReddit("<html><body><p>hi</p></body></html>", THREAD)).toBeNull();
  });
});

// Reddit's `.json` of a thread, as the extension embeds it (pruned, `<` escaped).
const POST_URL = "https://www.reddit.com/r/ClaudeCode/comments/1xf2lur/i_pointed_claude_code/";
type C = { id: string; author?: string; body?: string; replies?: C[]; more?: number; extra?: Record<string, unknown> };
const t1 = (c: C, depth = 0): unknown => ({
  kind: "t1",
  data: {
    id: c.id,
    author: c.author ?? `user_${c.id}`,
    score: 10,
    created_utc: 1792000000,
    body_html: `<div class="md"><p>${c.body ?? `Comment ${c.id} with enough words.`}</p></div>`,
    permalink: `/r/ClaudeCode/comments/1xf2lur/i_pointed_claude_code/${c.id}/`,
    depth,
    ...c.extra,
    replies: c.replies || c.more
      ? { kind: "Listing", data: { children: [...(c.replies ?? []).map((r) => t1(r, depth + 1)), ...(c.more ? [{ kind: "more", data: { count: c.more } }] : [])] } }
      : "",
  },
});
const threadJson = (comments: C[], post: Record<string, unknown> = {}, topMore = 0) => [
  {
    kind: "Listing",
    data: {
      children: [
        {
          kind: "t3",
          data: {
            title: "I pointed Claude Code at the cheap Chinese headphones",
            author: "op_user",
            subreddit_name_prefixed: "r/ClaudeCode",
            score: 1234,
            num_comments: 321,
            created_utc: 1791990000,
            selftext_html: '<div class="md"><p>So I reverse engineered the BLE protocol.</p></div>',
            url: POST_URL,
            permalink: "/r/ClaudeCode/comments/1xf2lur/i_pointed_claude_code/",
            is_self: true,
            ...post,
          },
        },
      ],
    },
  },
  { kind: "Listing", data: { children: [...comments.map((c) => t1(c)), ...(topMore ? [{ kind: "more", data: { count: topMore } }] : [])] } },
];
const captured = (json: unknown) =>
  `<!doctype html><html lang="en"><head><title>x</title></head><body><shreddit-app></shreddit-app>` +
  `<script type="application/json" id="sroka-reddit-json">${JSON.stringify(json).replace(/</g, "\\u003c")}</script></body></html>`;

describe("extractReddit from embedded thread JSON", () => {
  const deep: C = { id: "a", author: "op_user", extra: { is_submitter: true }, replies: [{ id: "b", replies: [{ id: "c", replies: [{ id: "d", replies: [{ id: "e", replies: [{ id: "f" }] }] }] }] }] };

  it("renders post card and comment cards with replies up to 3 levels", () => {
    const ex = extractReddit(captured(threadJson([deep, { id: "z", author: "AutoModerator", extra: { stickied: true } }], {}, 40)), POST_URL)!;
    expect(ex.title).toBe("I pointed Claude Code at the cheap Chinese headphones");
    expect(ex.byline).toBe("u/op_user in r/ClaudeCode");
    expect(ex.publishedTime).toBe(new Date(1791990000 * 1000).toISOString());
    expect(ex.excerpt).toBe("So I reverse engineered the BLE protocol.");
    const h = ex.contentHtml;
    expect(h).toContain('<div class="sr-thread">\n<div class="sr-post">');
    expect(h).toContain("1,234 points · 321 comments");
    expect(h).toContain(" <small>OP</small>");
    // a (top) > b > c > d shown; e and f collapsed into a link on d
    for (const id of ["a", "b", "c", "d"]) expect(h).toContain(`Comment ${id} with`);
    expect(h).not.toContain("Comment e with");
    expect(h).toContain('<a href="https://www.reddit.com/r/ClaudeCode/comments/1xf2lur/i_pointed_claude_code/d/">2 more replies on Reddit</a>');
    expect(h).not.toContain("AutoModerator");
    expect(h).toContain("321 comments · View all on Reddit");
    expect(ex.text).toContain("Comment d with");
  });

  it("highlights the saved comment and shows its parents and replies", () => {
    const url = `${POST_URL}c/`;
    const ex = extractReddit(captured(threadJson([deep])), url)!;
    const h = ex.contentHtml;
    expect(h).toContain('<div class="sr-reply sr-post-focus">');
    expect(h).toMatch(/sr-post-focus[^]*Comment c with/);
    // c is at depth 2: its replies d, e, f are all within 3 levels below it
    for (const id of ["a", "b", "c", "d", "e", "f"]) expect(h).toContain(`Comment ${id} with`);
    expect(ex.byline).toBe("u/user_c in r/ClaudeCode");
    expect(ex.excerpt).toBe("Comment c with enough words.");
    expect(h).toContain("View all 321 comments on Reddit");
  });

  it("keeps gallery images and external links; survives sanitizing", () => {
    const json = threadJson([{ id: "a", body: 'see <a href="/r/other">r/other</a>' }], {
      is_self: false,
      selftext_html: null,
      url: "https://example.org/story",
      gallery_data: { items: [{ media_id: "m2" }, { media_id: "m1" }] },
      media_metadata: { m1: { s: { u: "https://preview.redd.it/one.jpg?width=640&s=1" } }, m2: { s: { u: "https://i.redd.it/two.png" } } },
    });
    const ex = extractReddit(captured(json), POST_URL)!;
    expect(ex.leadImage).toBe("https://i.redd.it/two.png");
    expect(ex.contentHtml.match(/<img /g)).toHaveLength(2);
    expect(ex.contentHtml).toContain('<a href="https://example.org/story">');
    const san = sanitizeArticle(ex.contentHtml, POST_URL);
    expect(san.html).toContain('href="https://www.reddit.com/r/other"');
    expect(san.html).toContain('<div class="sr-comments">');
    expect(san.html).toContain('<div class="sr-post">');
  });

  it("falls back to shreddit markup when the JSON is broken", () => {
    const html = threadHtml.replace("</body>", '<script type="application/json" id="sroka-reddit-json">{oops</script></body>');
    expect(extractReddit(html, THREAD)?.contentHtml).toContain("u/alice");
  });
});

describe("Reddit block page", () => {
  it("is a bot-wall challenge", () => {
    expect(detectBotWall("<html><head><title>Reddit - Prove your humanity</title></head><body>Complete the challenge</body></html>")).toBe("challenge");
  });
});
