import { describe, expect, it } from "vitest";
import { VOCAB, failureReason } from "./index.ts";

describe("VOCAB", () => {
  it("holds the shared words", () => {
    expect(VOCAB.pending).toBe("Preparing…");
    expect(VOCAB.pendingTitle).toBe("Preparing article");
    expect(VOCAB.failed).toBe("Couldn't save the text");
    expect(VOCAB.paywalled).toBe("Preview only");
    expect(VOCAB.notDownloaded).toBe("Not on this device");
    expect(VOCAB.unsynced).toBe("Waiting to sync");
    expect(VOCAB.save).toBe("Save");
    expect(VOCAB.favorites).toBe("Favorites");
    expect(VOCAB.sendCode).toBe("Send code");
  });
});

describe("failureReason", () => {
  it.each([
    ["bot_wall", "The site blocks Sroka."],
    ["render_bot_wall", "The site blocks Sroka."],
    ["paywalled", "It's for subscribers only."],
    ["http_404", "The page is gone."],
    ["http_410", "The page is gone."],
    ["http_500", "The site didn't respond."],
    ["http_403", "The site didn't respond."],
    ["timeout", "The site didn't respond."],
    ["network", "The site didn't respond."],
    ["too_many_redirects", "The site didn't respond."],
    ["bad_redirect", "The site didn't respond."],
    ["too_large", "The page is too large."],
    ["render_too_large", "The page is too large."],
    ["pdf_too_large", "The page is too large."],
    ["not_html", "It isn't an article."],
  ])("%s → %s", (code, reason) => {
    expect(failureReason(code)).toBe(reason);
  });

  it("returns null for empty and unknown codes", () => {
    expect(failureReason(null)).toBeNull();
    expect(failureReason(undefined)).toBeNull();
    expect(failureReason("")).toBeNull();
    expect(failureReason("too_short")).toBeNull();
    expect(failureReason("constructor")).toBeNull();
    expect(failureReason("toString")).toBeNull();
  });
});
