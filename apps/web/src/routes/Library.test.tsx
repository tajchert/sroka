import type { Item } from "@sroka/shared";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { placeholderItem } from "../lib/cache.ts";

let items: Item[] = [];
vi.mock("../lib/lists.ts", () => ({
  useItemList: () => ({ query: { isPending: false, isError: false, isFetchingNextPage: false, refetch: () => undefined }, items }),
  useInfiniteScroll: () => () => undefined,
  useFollowNewItems: () => undefined,
  useStats: () => undefined,
}));
vi.mock("../lib/hooks.ts", async (orig) => ({
  ...(await orig<typeof import("../lib/hooks.ts")>()),
  useListKeyboard: () => [-1],
  useItemActions: () => new Proxy({}, { get: () => () => undefined }),
  useParsePolling: () => undefined,
}));
vi.mock("../components/Adder.tsx", () => ({ Adder: () => null }));
vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return { ...m, api: { ...m.api, meOrNull: async () => null, listTags: async () => [] } };
});

import Library from "./Library.tsx";

const show = (state: "unread" | "archived", path = "/") =>
  render(
    <QueryClientProvider client={new QueryClient()}>
      <MemoryRouter initialEntries={[path]}>
        <Library state={state} />
      </MemoryRouter>
    </QueryClientProvider>,
  );

describe("Library empty states", () => {
  afterEach(() => {
    cleanup();
    items = [];
  });

  it("shows the onboarding panel for an empty My List", () => {
    show("unread");
    expect(screen.getByText("Save from anywhere")).toBeTruthy();
  });

  it("drops the onboarding once there is one saved item", () => {
    items = [{ ...placeholderItem("https://example.com/a"), id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", parseStatus: "ok", title: "A" }];
    show("unread");
    expect(screen.queryByText("Save from anywhere")).toBeNull();
    expect(screen.getByText("A")).toBeTruthy();
  });

  it("keeps the plain text for other lists and for a site filter", () => {
    show("archived");
    expect(screen.getByText("Archive is empty")).toBeTruthy();
    expect(screen.queryByText("Save from anywhere")).toBeNull();
    cleanup();
    show("unread", "/?domain=example.com");
    expect(screen.getByText("Nothing from this site here")).toBeTruthy();
    expect(screen.queryByText("Save from anywhere")).toBeNull();
  });
});
