import { describe, expect, it } from "vitest";
import { extractFirstUrl, InvalidUrlError, isHttpUrl, normalizeUrl, urlHash } from "./url.ts";

describe("normalizeUrl", () => {
  const cases: [string, string][] = [
    ["HTTPS://Example.COM/Path?b=2&a=1#frag", "https://example.com/Path?a=1&b=2"],
    ["https://example.com:443/x", "https://example.com/x"],
    ["http://example.com:80/x", "http://example.com/x"],
    ["http://example.com:8080/x", "http://example.com:8080/x"],
    ["https://example.com", "https://example.com/"],
    ["https://example.com/post?utm_source=x&utm_Medium=y&id=5", "https://example.com/post?id=5"],
    ["https://example.com/?fbclid=1&gclid=2&dclid=3&msclkid=4&mc_eid=5&mc_cid=6&igshid=7&ref_src=8&_hsenc=9&_hsmktg=10&yclid=11", "https://example.com/"],
    ["https://example.com/a/", "https://example.com/a/"],
    ["https://www.example.com/a", "https://www.example.com/a"],
    ["https://user:pw@example.com/a", "https://example.com/a"],
    ["https://example.com./a", "https://example.com/a"],
    ["https://example.com/a?z=1&a=2&z=0", "https://example.com/a?a=2&z=1&z=0"],
    ["  https://example.com/a  ", "https://example.com/a"],
    ["https://bücher.de/", "https://xn--bcher-kva.de/"],
    ["https://example.com/a?q=hello world", "https://example.com/a?q=hello+world"],
  ];
  for (const [input, out] of cases) {
    it(`${input} → ${out}`, () => expect(normalizeUrl(input)).toBe(out));
  }
  it("is idempotent", () => {
    for (const [, out] of cases) expect(normalizeUrl(out)).toBe(out);
  });
  it("rejects non-http", () => {
    expect(() => normalizeUrl("ftp://x.com/")).toThrow(InvalidUrlError);
    expect(() => normalizeUrl("javascript:alert(1)")).toThrow(InvalidUrlError);
    expect(() => normalizeUrl("not a url")).toThrow(InvalidUrlError);
  });
});

describe("isHttpUrl", () => {
  it("works", () => {
    expect(isHttpUrl("https://a.b")).toBe(true);
    expect(isHttpUrl("mailto:a@b.c")).toBe(false);
    expect(isHttpUrl("/relative")).toBe(false);
  });
});

describe("urlHash", () => {
  it("is sha256 hex", async () => {
    expect(await urlHash("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
});

describe("extractFirstUrl", () => {
  it("finds url in share text", () => {
    expect(extractFirstUrl("Great read https://example.com/a?b=1 via @app")).toBe("https://example.com/a?b=1");
  });
  it("strips trailing punctuation and unbalanced parens", () => {
    expect(extractFirstUrl("(see https://example.com/x).")).toBe("https://example.com/x");
    expect(extractFirstUrl("https://en.wikipedia.org/wiki/Foo_(bar)")).toBe("https://en.wikipedia.org/wiki/Foo_(bar)");
    expect(extractFirstUrl('"https://example.com/q"!')).toBe("https://example.com/q");
  });
  it("returns null when absent", () => {
    expect(extractFirstUrl("no links here")).toBeNull();
  });
});
