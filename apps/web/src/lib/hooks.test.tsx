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
import { flushPendingDeletes, installPendingDeleteFlush, useItemActions } from "./hooks.ts";

const a: Item = { ...placeholderItem("https://example.com/a"), id: "a" };
const b: Item = { ...placeholderItem("https://example.com/b"), id: "b" };
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

  it("a delete queued while a flush is in flight is neither lost nor sent twice", async () => {
    vi.useFakeTimers();
    let finishA!: () => void;
    deleteItem.mockImplementation((id: string) => (id === "a" ? new Promise<void>((r) => (finishA = r)) : Promise.resolve()));
    const { wrapper } = setup();
    const { result } = renderHook(() => useItemActions(), { wrapper });
    act(() => result.current.remove(a));
    const flushing = flushPendingDeletes();
    expect(deleteItem).toHaveBeenCalledTimes(1);
    act(() => result.current.remove(b)); // enqueued while a's delete is still in flight
    finishA();
    await act(() => flushing);
    expect(deleteItem).toHaveBeenCalledTimes(1); // the flush did not take b
    await act(() => vi.advanceTimersByTimeAsync(7000));
    expect(deleteItem.mock.calls.map((c) => c[0])).toEqual(["a", "b"]); // a's timer did not re-send it
  });
});
