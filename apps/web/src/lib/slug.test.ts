import type { Item } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { placeholderItem } from "./cache.ts";
import { itemTitle } from "./hooks.ts";
import { titleFromUrl } from "./slug.ts";

describe("titleFromUrl", () => {
  it("de-hyphenates and sentence-cases the last path segment", () => {
    expect(titleFromUrl("https://example.com/blog/why-sqlite-is-fast")).toBe("Why sqlite is fast");
    expect(titleFromUrl("https://example.com/a/how_to_cook")).toBe("How to cook");
  });
  it("ignores extension, query, hash and trailing slash", () => {
    expect(titleFromUrl("https://example.com/2024/the-long-read.html?utm_source=x#top")).toBe("The long read");
    expect(titleFromUrl("https://example.com/the-long-read/")).toBe("The long read");
  });
  it("drops date and id tokens", () => {
    expect(titleFromUrl("https://example.com/2024-05-12-my-post")).toBe("My post");
    expect(titleFromUrl("https://medium.com/@a/my-story-title-1a2b3c4d5e6f")).toBe("My story title");
  });
  it("skips id-only and generic segments, walking up the path", () => {
    expect(titleFromUrl("https://example.com/news/12345")).toBe("News");
    expect(titleFromUrl("https://example.com/great-piece/amp")).toBe("Great piece");
    expect(titleFromUrl("https://example.com/p/8f3a9c1d2e4b")).toBeNull();
  });
  it("decodes percent escapes", () => {
    expect(titleFromUrl("https://example.com/caf%C3%A9-culture")).toBe("Café culture");
  });
  it("returns null without a usable slug", () => {
    expect(titleFromUrl("https://example.com/")).toBeNull();
    expect(titleFromUrl("https://example.com/?id=3")).toBeNull();
    expect(titleFromUrl("not a url")).toBeNull();
  });
});

describe("itemTitle", () => {
  const pending = (url: string, over: Partial<Item> = {}): Item => ({ ...placeholderItem(url), ...over });
  it("uses the URL slug for a pending item without a title", () => {
    expect(itemTitle(pending("https://www.example.com/blog/why-sqlite-is-fast"))).toBe("Why sqlite is fast");
  });
  it("falls back to the host when the slug is unusable", () => {
    expect(itemTitle(pending("https://www.example.com/"))).toBe("example.com");
  });
  it("prefers the real title, and does not slug finished items", () => {
    expect(itemTitle(pending("https://example.com/x-y-z", { title: "Real" }))).toBe("Real");
    expect(itemTitle(pending("https://example.com/some-slug", { parseStatus: "failed" }))).toBe("example.com");
  });
});
