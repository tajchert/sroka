import { describe, expect, it } from "vitest";
import { failedBody, FAILED_TRY_AGAIN } from "./save-failure.ts";

describe("failedBody", () => {
  it("never repeats the title", () => {
    expect(failedBody(undefined)).toBe(FAILED_TRY_AGAIN);
    expect(failedBody("Could not save this page.")).toBe(FAILED_TRY_AGAIN);
    expect(failedBody("This page can't be saved.")).toBe(FAILED_TRY_AGAIN);
  });
  it("keeps a specific message", () => {
    expect(failedBody("Can't reach the server.")).toBe("Can't reach the server.");
  });
});
