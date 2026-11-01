import type { Item } from "@sroka/shared";
import { cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { insertedAbove, useFollowNewItems } from "./lists.ts";

const items = (...ids: string[]) => ids.map((id) => ({ id }) as Item);

describe("insertedAbove", () => {
  it("is true only when the old first row moved down", () => {
    expect(insertedAbove("old", ["new2", "new1", "old"])).toBe(true);
    expect(insertedAbove("gone", ["b", "c"])).toBe(false);
    expect(insertedAbove("a", ["a", "b"])).toBe(false);
    expect(insertedAbove(undefined, ["a"])).toBe(false);
  });
});

describe("useFollowNewItems", () => {
  let scrollTo: ReturnType<typeof vi.fn>;
  beforeEach(() => {
    const root = document.createElement("main");
    root.id = "scroll-root";
    scrollTo = vi.fn();
    root.scrollTo = scrollTo as unknown as typeof root.scrollTo;
    document.body.appendChild(root);
  });
  afterEach(() => {
    cleanup();
    document.getElementById("scroll-root")?.remove();
  });

  const render = (initial: { list: Item[]; key: string; enabled: boolean }) =>
    renderHook(({ list, key, enabled }) => useFollowNewItems(list, key, enabled), { initialProps: initial });

  it("scrolls to the top when items arrive above the first row", () => {
    const { rerender } = render({ list: items("a", "b"), key: "unread", enabled: true });
    expect(scrollTo).not.toHaveBeenCalled();
    rerender({ list: items("n", "a", "b"), key: "unread", enabled: true });
    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: "smooth" });
  });

  it("stays put on deletes, list switches and non-newest sorts", () => {
    const { rerender } = render({ list: items("a", "b"), key: "unread", enabled: true });
    rerender({ list: items("b"), key: "unread", enabled: true });
    rerender({ list: items("x", "b"), key: "archived", enabled: true });
    rerender({ list: items("y", "x", "b"), key: "archived", enabled: false });
    expect(scrollTo).not.toHaveBeenCalled();
  });
});
