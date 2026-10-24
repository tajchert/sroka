import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

const getContent = vi.fn();
vi.mock("../lib/api.ts", async (orig) => {
  const m = await orig<typeof import("../lib/api.ts")>();
  return { ...m, api: { ...m.api, getContent: (...a: unknown[]) => getContent(...a) } };
});

import { loadPdfBlob, usePdfBlob } from "./PdfViewer.tsx";

const ok = () => new Response(new Blob(["%PDF"]), { status: 200 });
const status = (n: number) => new Response("", { status: n });

describe("loadPdfBlob", () => {
  it("re-signs once on 403 and fetches the fresh URL", async () => {
    const fetchImpl = vi.fn().mockResolvedValueOnce(status(403)).mockResolvedValueOnce(ok());
    const resign = vi.fn().mockResolvedValue("new");
    const blob = await loadPdfBlob({ url: "old", fresh: false, resign, fetchImpl });
    expect(blob.type).toBe("application/pdf");
    expect(fetchImpl.mock.calls.map((c) => c[0])).toEqual(["old", "new"]);
    expect(resign).toHaveBeenCalledTimes(1);
  });

  it("does not loop: a second 403 fails", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(status(403));
    const resign = vi.fn().mockResolvedValue("new");
    await expect(loadPdfBlob({ url: "old", fresh: false, resign, fetchImpl })).rejects.toThrow();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("fresh retry never uses the old URL", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(ok());
    await loadPdfBlob({ url: "old", fresh: true, resign: async () => "new", fetchImpl });
    expect(fetchImpl.mock.calls.map((c) => c[0])).toEqual(["new"]);
  });
});

describe("usePdfBlob retry", () => {
  afterEach(() => vi.restoreAllMocks());
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>;

  it("Try again after expiry fetches the re-signed URL on the first click", async () => {
    URL.createObjectURL = vi.fn(() => "blob:x");
    URL.revokeObjectURL = vi.fn();
    getContent.mockResolvedValueOnce({ documentUrl: "expired" }).mockResolvedValue({ documentUrl: "fresh" });
    const calls: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (u: string) => { calls.push(u); return u === "expired" ? status(500) : ok(); }));
    const { result } = renderHook(() => usePdfBlob("i1", "c1"), { wrapper });
    await waitFor(() => expect(result.current.error).toBe(true));
    act(() => result.current.retry());
    await waitFor(() => expect(result.current.url).toBe("blob:x"));
    expect(calls).toEqual(["expired", "fresh"]);
    vi.unstubAllGlobals();
  });
});
