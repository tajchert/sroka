import { describe, expect, it } from "vitest";
import { sharedLink } from "./Share.tsx";

const q = (o: Record<string, string>) => new URLSearchParams(o);

describe("sharedLink", () => {
  it("prefers the url field", () => {
    expect(sharedLink(q({ url: "https://a.example/x", text: "see https://b.example" }))).toBe("https://a.example/x");
  });
  it("finds a link inside text, without trailing punctuation", () => {
    expect(sharedLink(q({ title: "Great read", text: "Look at this (https://b.example/p?q=1)." }))).toBe("https://b.example/p?q=1");
  });
  it("returns null when nothing shared is a link", () => {
    expect(sharedLink(q({ title: "Hello", text: "no links here" }))).toBeNull();
  });
});
