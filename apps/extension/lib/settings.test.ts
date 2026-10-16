import { beforeEach, describe, expect, it } from "vitest";
import { getPendingOtp, setPendingOtp } from "./settings.ts";
import { installChrome } from "./test-chrome.ts";

beforeEach(() => {
  installChrome();
});

describe("pending OTP", () => {
  it("survives a popup reopen until the code expires", async () => {
    await setPendingOtp("a@b.co", 1_000);
    expect(await getPendingOtp(1_000 + 60_000)).toBe("a@b.co");
    expect(await getPendingOtp(1_000 + 5 * 60_000)).toBeNull();
  });

  it("is cleared with null", async () => {
    await setPendingOtp("a@b.co");
    await setPendingOtp(null);
    expect(await getPendingOtp()).toBeNull();
  });
});
