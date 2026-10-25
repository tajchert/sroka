import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { sortOptions, useListSort } from "./sort.ts";

describe("useListSort", () => {
  afterEach(() => {
    cleanup();
    localStorage.clear();
  });

  it("defaults per list and remembers each list's choice separately", () => {
    const { result, rerender } = renderHook(({ list }) => useListSort(list), { initialProps: { list: "unread" as const } as { list: "unread" | "archived" } });
    expect(result.current[0]).toBe("newest");
    act(() => result.current[1]("shortest"));
    expect(result.current[0]).toBe("shortest");
    rerender({ list: "archived" });
    expect(result.current[0]).toBe("archived");
    rerender({ list: "unread" });
    expect(result.current[0]).toBe("shortest");
  });

  it("ignores a stored sort the list does not offer", () => {
    localStorage.setItem("sroka.sort.unread", "archived");
    const { result } = renderHook(() => useListSort("unread"));
    expect(result.current[0]).toBe("newest");
    expect(sortOptions("archived").map((o) => o.label)).toEqual(["Recently archived", "Oldest first", "Shortest read"]);
  });
});
