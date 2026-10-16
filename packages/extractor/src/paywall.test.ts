import { describe, expect, it } from "vitest";
import { detectPaywall } from "./paywall.ts";

describe("detectPaywall", () => {
  it("JSON-LD isAccessibleForFree false (bool or string), nested", () => {
    expect(detectPaywall(`<script type="application/ld+json">{"@type":"Article","isAccessibleForFree":false}</script>`)).toBe(true);
    expect(detectPaywall(`<script type='application/ld+json'>{"hasPart":{"isAccessibleForFree": "False"}}</script>`)).toBe(true);
  });
  it("content_tier locked meta in either attribute order, Medium banner", () => {
    expect(detectPaywall(`<meta property="article:content_tier" content="locked">`)).toBe(true);
    expect(detectPaywall(`<meta content="locked" name="article:content_tier">`)).toBe(true);
    expect(detectPaywall(`<div><span>Member-only story</span></div>`)).toBe(true);
  });
  it("free content and prose mentions are not paywalled", () => {
    expect(detectPaywall(`<script type="application/ld+json">{"isAccessibleForFree":true}</script>`)).toBe(false);
    expect(detectPaywall(`<meta property="article:content_tier" content="free">`)).toBe(false);
    expect(detectPaywall(`<p>I wrote a Member-only story about it last year.</p>`)).toBe(false);
    expect(detectPaywall(`<p>"isAccessibleForFree": false appears in code samples</p>`)).toBe(false);
  });
});
