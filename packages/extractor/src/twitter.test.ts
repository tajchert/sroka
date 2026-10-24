import { describe, expect, it } from "vitest";
import { sanitizeArticle } from "./sanitize.ts";
import { extractTweet, formatTweetDate, parseFxThread, parseSyndication, renderTweets, syndicationToken, tweetRef } from "./twitter.ts";

// Trimmed FxTwitter API v2 shapes (fields as api.fxtwitter.com/2/thread/{id} serves them).
const author = (screen_name: string, name: string) => ({
  screen_name,
  name,
  url: `https://x.com/${screen_name}`,
  avatar_url: `https://pbs.twimg.com/profile_images/1/${screen_name}_200x200.jpg`,
});
const status = (id: string, over: Record<string, unknown> = {}) => ({
  type: "status",
  id,
  url: `https://x.com/ann/status/${id}`,
  text: "",
  raw_text: { text: "", display_text_range: [0, 0], facets: [] },
  author: author("ann", "Ann Example"),
  created_at: "Sat Oct 24 01:41:45 +0000 2026",
  created_timestamp: 1792806105,
  likes: 968,
  reposts: 38,
  replies: 31,
  quotes: 0,
  views: 38931,
  lang: "en",
  replying_to: null,
  media: {},
  community_note: null,
  ...over,
});

const t1 = status("100", {
  raw_text: {
    text: "Big news &amp; more!\n\nRead https://t.co/AAA thanks @bob #design https://t.co/MED",
    facets: [
      { type: "url", indices: [0, 0], original: "https://t.co/AAA", replacement: "https://example.com/post?a=1", display: "example.com/post" },
      { type: "mention", indices: [0, 0], original: "bob" },
      { type: "media", indices: [0, 0], original: "https://t.co/MED", replacement: "https://x.com/ann/status/100/video/1" },
    ],
  },
  media: { all: [{ type: "video", url: "https://video.twimg.com/v.mp4", thumbnail_url: "https://pbs.twimg.com/amplify_video_thumb/1/img/p.jpg", duration: 70.4, width: 1, height: 1 }] },
  quote: status("50", {
    url: "https://x.com/carl/status/50",
    author: author("carl", "Carl"),
    raw_text: { text: "The original announcement", facets: [] },
    created_timestamp: 1792712241,
  }),
});
const t2 = status("101", {
  raw_text: { text: "Second post with a photo", facets: [] },
  media: { all: [{ type: "photo", url: "https://pbs.twimg.com/media/HVW.jpg?name=orig", width: 2160, height: 2160, altText: "A phone" }] },
});
const thread = { code: 200, status: t2, thread: [t1, t2] };

const html = (url: string, json: unknown) => {
  const p = parseFxThread(json)!;
  const ex = renderTweets(p.tweets, p.focusId)!;
  return { ex, html: sanitizeArticle(ex.contentHtml, url).html };
};

describe("tweetRef", () => {
  it("recognises status URLs on x.com / twitter.com and mirrors", () => {
    expect(tweetRef("https://x.com/RobertJBye/status/2113808129368760750")).toEqual({ id: "2113808129368760750", user: "RobertJBye" });
    expect(tweetRef("https://mobile.twitter.com/a_b/status/123/photo/1?s=20")).toEqual({ id: "123", user: "a_b" });
    expect(tweetRef("https://x.com/i/web/status/123")).toEqual({ id: "123", user: null });
    expect(tweetRef("https://fxtwitter.com/a/status/9")).toEqual({ id: "9", user: "a" });
    expect(tweetRef("https://x.com/RobertJBye")).toBeNull();
    expect(tweetRef("https://notx.com/a/status/1")).toBeNull();
  });

  it("computes the embed token and formats dates in UTC", () => {
    expect(syndicationToken("20")).toMatch(/^[0-9a-z]+$/);
    expect(formatTweetDate("2026-10-24T01:41:45.000Z")).toBe("Oct 24, 2026, 1:41 AM UTC");
  });
});

describe("FxTwitter thread", () => {
  it("renders the whole author thread from a middle post as cards, with quote, media and stats", () => {
    const { ex, html: out } = html("https://x.com/ann/status/101", thread);
    expect(ex).toMatchObject({
      title: "Big news & more!",
      byline: "Ann Example (@ann)",
      siteName: "X",
      lang: "en",
      publishedTime: "2026-10-24T01:41:45.000Z",
      leadImage: "https://pbs.twimg.com/amplify_video_thumb/1/img/p.jpg",
    });
    // one card per post in a thread stack, each with avatar, author and linked date
    expect(out).toMatch(/^<div class="sr-thread">\n<div class="sr-post"><p class="sr-post-head"><img src="https:\/\/pbs.twimg.com\/profile_images\/1\/ann_200x200.jpg"[^>]* class="sr-avatar" \/> <span class="sr-post-who"><strong>Ann Example<\/strong>/);
    expect(out.match(/<div class="sr-post">/g)).toHaveLength(2);
    expect(out.match(/@ann<\/a>/g)).toHaveLength(2);
    expect(out).toContain('<time datetime="2026-10-24T01:41:45.000Z">Oct 24, 2026, 1:41 AM UTC</time>');
    // text: entities decoded, t.co expanded, media link dropped, mention + hashtag linked, paragraphs kept
    expect(out).toContain("<p>Big news &amp; more!</p>");
    expect(out).toContain('<a href="https://example.com/post?a=1" rel="noopener noreferrer nofollow" target="_blank">example.com/post</a>');
    expect(out).not.toContain("t.co/");
    expect(out).toContain('href="https://x.com/bob"');
    expect(out).toContain('href="https://x.com/search?q=%23design"');
    // video poster + caption, photo at large size with alt
    expect(out).toContain("▶ Video · 1:10");
    expect(out).toContain('src="https://pbs.twimg.com/media/HVW?format=jpg&amp;name=large"');
    expect(out).toContain("<figcaption>A phone</figcaption>");
    // quoted post as blockquote with its own author + date
    expect(out).toMatch(
      /<blockquote class="sr-post sr-post-quote"><p class="sr-post-head">.*<strong>Carl<\/strong>.*Oct 22, 2026.*<\/p><div class="sr-post-body"><p>The original announcement<\/p><\/div><\/blockquote>/s,
    );
    expect(out).toContain('<p class="sr-post-stats"><small>31 replies · 38 reposts · 968 likes · 38,931 views</small></p>');
    expect(out).toMatch(/<p class="sr-thread-foot"><small>Thread · 2 posts · <a href="https:\/\/x.com\/ann\/status\/100"/);
    expect(ex.text).toContain("Second post with a photo");
    expect(ex.text).toContain("The original announcement");
  });

  it("shows a reply's parent as quoted context and strips the leading @mention", () => {
    const reply = status("200", {
      url: "https://x.com/zed/status/200",
      author: author("zed", "Zed"),
      raw_text: { text: "@ann @carl Great thread", facets: [] },
      replying_to: { screen_name: "ann", status: "100" },
      likes: 0,
      reposts: 0,
      replies: 0,
      views: 0,
    });
    const { ex, html: out } = html("https://x.com/zed/status/200", { code: 200, status: reply, thread: [t1, reply] });
    expect(ex.title).toBe("Great thread");
    expect(ex.byline).toBe("Zed (@zed)");
    expect(out).toMatch(/^<div class="sr-thread">\n<div class="sr-post"><p class="sr-post-head">.*?<strong>Ann Example<\/strong>/);
    expect(out).toMatch(/<div class="sr-post sr-post-focus">.*?<strong>Zed<\/strong>.*?<p>Great thread<\/p>/s);
    expect(out).not.toContain("Replying to"); // the parent is shown
    expect(out).not.toMatch(/0 likes|0 replies/);
  });

  it("notes 'Replying to' when the parent isn't included; polls, cards, notes and unavailable quotes", () => {
    const t = status("300", {
      raw_text: { text: "@someone Which one? https://t.co/CRD", facets: [{ type: "url", original: "https://t.co/CRD", replacement: "https://blog.example/x", display: "blog.example/x" }] },
      replying_to: { screen_name: "someone", status: "1" },
      poll: { choices: [{ label: "Tabs", count: 3, percentage: 75 }, { label: "Spaces", count: 1, percentage: 25 }], total_votes: 4, ends_at: "2020-01-01T00:00:00Z", time_left_en: "Final results" },
      card: { url: "https://blog.example/x", title: "A blog post", description: "About things", domain: "blog.example" },
      community_note: { text: "Context added by readers.", facets: [] },
      quote: { type: "tombstone", reason: "deleted", message: "This post was deleted.", url: "https://x.com/q/status/5" },
    });
    const { html: out } = html("https://x.com/ann/status/300", { code: 200, status: t, thread: [] });
    expect(out).toContain('Replying to <a href="https://x.com/someone"');
    expect(out).toContain("<li>Tabs — 75%</li>");
    expect(out).toContain("Poll · 4 votes · final results");
    expect(out).toContain("Context added by readers.");
    expect(out).toContain("This post was deleted.");
    // a quote suppresses the link card
    expect(out).not.toContain("A blog post");
  });

  it("renders an X Article body (headings, lists, inline styles, links, media, code)", () => {
    const t = status("400", {
      raw_text: { text: "https://t.co/ART", facets: [{ type: "url", original: "https://t.co/ART", replacement: "https://x.com/i/article/9", display: "x.com/i/article/9" }] },
      article: {
        id: "9",
        title: "How we built it",
        preview_text: "",
        created_at: "",
        cover_media: { id: "c", media_id: "c", media_key: "3_c", media_info: { __typename: "ApiImage", original_img_url: "https://pbs.twimg.com/media/cover.jpg" } },
        media_entities: [{ id: "m1", media_id: "m1", media_key: "3_m1", media_info: { __typename: "ApiImage", original_img_url: "https://pbs.twimg.com/media/m1.jpg" } }],
        content: {
          blocks: [
            { key: "a", type: "header-one", text: "Intro", data: {}, entityRanges: [], inlineStyleRanges: [] },
            { key: "b", type: "unstyled", text: "Bold and a link.", data: {}, entityRanges: [{ key: 0, offset: 11, length: 4 }], inlineStyleRanges: [{ offset: 0, length: 4, style: "Bold" }] },
            { key: "c", type: "unordered-list-item", text: "one", data: {}, entityRanges: [], inlineStyleRanges: [] },
            { key: "d", type: "unordered-list-item", text: "two", data: {}, entityRanges: [], inlineStyleRanges: [] },
            { key: "e", type: "atomic", text: " ", data: {}, entityRanges: [{ key: 1, offset: 0, length: 1 }], inlineStyleRanges: [] },
            { key: "f", type: "atomic", text: " ", data: {}, entityRanges: [{ key: 2, offset: 0, length: 1 }], inlineStyleRanges: [] },
          ],
          entityMap: [
            { key: "0", value: { type: "LINK", mutability: "Mutable", data: { url: "https://example.com/" } } },
            { key: "1", value: { type: "MEDIA", mutability: "Immutable", data: { entityKey: "1", mediaItems: [{ localMediaId: "x", mediaCategory: "DraftTweetImage", mediaId: "m1" }] } } },
            { key: "2", value: { type: "MARKDOWN", mutability: "Mutable", data: { entityKey: "2", markdown: "```ts\nconst a = 1 < 2;\n```" } } },
          ],
        },
      },
    });
    const { ex, html: out } = html("https://x.com/ann/status/400", { code: 200, status: t, thread: [t] });
    expect(ex.title).toBe("How we built it");
    expect(ex.leadImage).toBe("https://pbs.twimg.com/media/cover.jpg");
    expect(out).not.toContain("x.com/i/article/9");
    expect(out).toContain("<h2>How we built it</h2>");
    expect(out).toContain("<h2>Intro</h2>");
    expect(out).toContain('<p><strong>Bold</strong> and a <a href="https://example.com/"');
    expect(out).toContain("<ul><li>one</li><li>two</li></ul>");
    expect(out).toContain('src="https://pbs.twimg.com/media/m1.jpg"');
    expect(out).toContain("<pre><code>const a = 1 &lt; 2;</code></pre>");
  });
});

describe("syndication fallback", () => {
  const synd = {
    __typename: "Tweet",
    id_str: "500",
    created_at: "2026-10-24T01:41:45.000Z",
    lang: "en",
    text: "@ann Yes &gt; no https://t.co/L https://t.co/P",
    in_reply_to_screen_name: "ann",
    favorite_count: 12,
    conversation_count: 2,
    user: { screen_name: "bob", name: "Bob" },
    entities: { urls: [{ url: "https://t.co/L", expanded_url: "https://example.org/", display_url: "example.org" }], media: [{ url: "https://t.co/P" }] },
    mediaDetails: [{ type: "photo", media_url_https: "https://pbs.twimg.com/media/P.png", ext_alt_text: "chart" }],
    parent: { __typename: "Tweet", id_str: "499", created_at: "2026-10-23T01:00:00.000Z", text: "Is it?", user: { screen_name: "ann", name: "Ann" } },
  };

  it("maps the embed JSON (parent as context, entities, media)", () => {
    const p = parseSyndication(synd)!;
    const ex = renderTweets(p.tweets, p.focusId)!;
    const out = sanitizeArticle(ex.contentHtml, "https://x.com/bob/status/500").html;
    expect(ex.byline).toBe("Bob (@bob)");
    expect(out).toMatch(/^<div class="sr-thread">\n<div class="sr-post">.*Is it\?.*<div class="sr-post sr-post-focus">.*Yes/s);
    expect(out).toContain("<p>Yes &gt; no <a href=\"https://example.org/\"");
    expect(out).toContain('src="https://pbs.twimg.com/media/P?format=png&amp;name=large"');
    expect(out).toContain("2 replies · 12 likes");
  });

  it("extractTweet tries FxTwitter, then the embed API, then gives up", async () => {
    const calls: string[] = [];
    const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
    const fetchFx = (async (u: string) => {
      calls.push(u);
      return u.startsWith("https://api.fxtwitter.com/") ? json(thread) : new Response("x", { status: 404 });
    }) as unknown as typeof fetch;
    expect((await extractTweet("https://x.com/ann/status/101", { fetch: fetchFx }))?.title).toBe("Big news & more!");
    expect(calls).toEqual(["https://api.fxtwitter.com/2/thread/101"]);

    const fetchSynd = (async (u: string) => (u.startsWith("https://cdn.syndication.twimg.com/") ? json(synd) : new Response("down", { status: 503 }))) as unknown as typeof fetch;
    expect((await extractTweet("https://x.com/bob/status/500", { fetch: fetchSynd }))?.byline).toBe("Bob (@bob)");

    const fetchNone = (async () => new Response("nf", { status: 404 })) as unknown as typeof fetch;
    expect(await extractTweet("https://x.com/bob/status/500", { fetch: fetchNone })).toBeNull();
    expect(await extractTweet("https://example.com/a/status/1", { fetch: fetchNone })).toBeNull();
  });
});
