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
    expect(ex.contentHtml).toContain("r/AskReddit · u/songfan · 5,120 points · 3,400 comments");
    expect(ex.contentHtml).toContain("<h2>Comments</h2>");
    // reply nesting: bob inside alice, carol kept under a [deleted] placeholder
    expect(ex.contentHtml).toMatch(/u\/alice[\s\S]*<blockquote><p><small><strong>u\/bob<\/strong>[\s\S]*\[deleted\][\s\S]*u\/carol/);
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
    expect(san.html).toContain("<blockquote>");
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

describe("Reddit block page", () => {
  it("is a bot-wall challenge", () => {
    expect(detectBotWall("<html><head><title>Reddit - Prove your humanity</title></head><body>Complete the challenge</body></html>")).toBe("challenge");
  });
});
