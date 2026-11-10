import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook } from "@testing-library/react";
import type { Item } from "@sroka/shared";
import type { ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

const updateItem = vi.fn();
const deleteItem = vi.fn();
vi.mock("./store.tsx", () => ({ useToasts: () => ({ push: () => undefined }), hideItem: () => undefined, unhideItem: () => undefined }));
vi.mock("./analytics.ts", () => ({ track: () => undefined }));
vi.mock("react-router", () => ({ useNavigate: () => () => undefined }));
vi.mock("./api.ts", async (orig) => {
  const m = await orig<typeof import("./api.ts")>();
  return { ...m, api: { ...m.api, updateItem: (...a: unknown[]) => updateItem(...a), deleteItem: (...a: unknown[]) => deleteItem(...a) } };
});

import { itemsKey, placeholderItem, type ItemsData } from "./cache.ts";
import { installPendingDeleteFlush, useItemActions } from "./hooks.ts";

const a: Item = { ...placeholderItem("https://example.com/a"), id: "a" };
const unread = { state: "unread", sort: "newest" } as const;

function setup() {
  const qc = new QueryClient();
  qc.setQueryData<ItemsData>(itemsKey(unread), { pages: [{ items: [a], nextCursor: null }], pageParams: [undefined] });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  const ids = () => qc.getQueryData<ItemsData>(itemsKey(unread))!.pages.flatMap((pg) => pg.items.map((i) => i.id));
  return { wrapper, ids };
}

describe("useItemActions", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it("a failed archive puts the item back in the list", async () => {
    const { wrapper, ids } = setup();
    updateItem.mockRejectedValue(new Error("offline"));
    const { result } = renderHook(() => useItemActions(), { wrapper });
    await act(() => result.current.setArchived(a, true));
    expect(ids()).toEqual(["a"]);
  });

  it("pagehide sends a pending delete once and skips the timer", () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn(async (..._args: unknown[]) => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);
    installPendingDeleteFlush();
    const { wrapper } = setup();
    const { result } = renderHook(() => useItemActions(), { wrapper });
    act(() => result.current.remove(a));
    window.dispatchEvent(new Event("pagehide"));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith("/v1/items/a", expect.objectContaining({ method: "DELETE", keepalive: true }));
    vi.advanceTimersByTime(7000);
    expect(deleteItem).not.toHaveBeenCalled();
  });
});
