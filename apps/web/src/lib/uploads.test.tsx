import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const pending: { file: File; resolve: (v: unknown) => void; reject: (e: unknown) => void }[] = [];
vi.mock("./pdf.ts", async (orig) => ({
  ...(await orig<typeof import("./pdf.ts")>()),
  uploadPdf: (file: File) => {
    let resolve!: (v: unknown) => void;
    let reject!: (e: unknown) => void;
    const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
    pending.push({ file, resolve, reject });
    return { promise, abort: () => undefined };
  },
}));
const toastsPushed: unknown[] = [];
vi.mock("./store.tsx", () => ({ useToasts: () => ({ push: (t: unknown) => toastsPushed.push(t) }) }));
const renderThumb = vi.fn<(f: Blob) => Promise<Blob | null>>();
vi.mock("./pdf-thumb.ts", () => ({ renderPdfThumbnail: (f: Blob) => renderThumb(f) }));
const putThumbnail = vi.fn<(id: string, b: Blob) => Promise<unknown>>();
vi.mock("./api.ts", async (orig) => {
  const m = await orig<typeof import("./api.ts")>();
  return { ...m, api: { ...m.api, putThumbnail: (id: string, b: Blob) => putThumbnail(id, b) } };
});
vi.mock("./error-reporting.ts", () => ({ reportClientError: () => true }));

import { placeholderItem } from "./cache.ts";
import { usePdfUploads } from "./uploads.ts";

const pdf = (n: string) => new File([new Uint8Array([37, 80, 68, 70])], n, { type: "application/pdf" });

describe("usePdfUploads queue", () => {
  beforeEach(() => { pending.length = 0; });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>;

  it("starts 2 uploads, the rest wait, and retry re-enters the queue", async () => {
    const { result } = renderHook(() => usePdfUploads(), { wrapper });
    act(() => result.current.addFiles([pdf("a.pdf"), pdf("b.pdf"), pdf("c.pdf")]));
    expect(pending.map((p) => p.file.name)).toEqual(["a.pdf", "b.pdf"]);
    expect(result.current.rows.map((r) => r.state)).toEqual(["uploading", "uploading", "queued"]);

    await act(async () => pending[0]!.reject(new Error("net")));
    expect(pending.map((p) => p.file.name)).toEqual(["a.pdf", "b.pdf", "c.pdf"]);
    expect(result.current.rows.map((r) => r.state)).toEqual(["error", "uploading", "uploading"]);

    act(() => result.current.retry(result.current.rows[0]!.key));
    // two slots busy (b, c): a waits
    expect(result.current.rows[0]!.state).toBe("queued");
    expect(pending).toHaveLength(3);
    await act(async () => pending[1]!.reject(new Error("net")));
    expect(pending.map((p) => p.file.name)).toEqual(["a.pdf", "b.pdf", "c.pdf", "a.pdf"]);
  });
});

describe("usePdfUploads first-page preview", () => {
  beforeEach(() => {
    pending.length = 0;
    toastsPushed.length = 0;
    renderThumb.mockReset();
    putThumbnail.mockReset();
  });
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>;
  const item = (leadImageKey: string | null) => ({
    ...placeholderItem("https://sroka.app/pdf/" + "a".repeat(64)),
    id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
    kind: "pdf" as const,
    leadImageKey,
  });
  const flush = () => new Promise((r) => setTimeout(r, 0));

  it("renders page 1 and uploads it for a new item without a preview", async () => {
    const thumb = new Blob([new Uint8Array([1])], { type: "image/webp" });
    renderThumb.mockResolvedValue(thumb);
    putThumbnail.mockResolvedValue({ ...item("thumb.webp"), leadImageUrl: "https://c/x/thumb.webp" });
    const { result } = renderHook(() => usePdfUploads(), { wrapper });
    const f = pdf("a.pdf");
    act(() => result.current.addFiles([f]));
    await act(async () => { pending[0]!.resolve({ item: item(null), created: true }); await flush(); });
    expect(renderThumb).toHaveBeenCalledWith(f);
    expect(putThumbnail).toHaveBeenCalledWith(item(null).id, thumb);
    expect(result.current.rows).toEqual([]);
  });

  it("skips a duplicate that already has a preview", async () => {
    const { result } = renderHook(() => usePdfUploads(), { wrapper });
    act(() => result.current.addFiles([pdf("a.pdf")]));
    await act(async () => { pending[0]!.resolve({ item: item("thumb.webp"), created: false }); await flush(); });
    expect(renderThumb).not.toHaveBeenCalled();
  });

  it("a failed render or preview upload never surfaces to the user", async () => {
    renderThumb.mockResolvedValueOnce(null);
    renderThumb.mockResolvedValueOnce(new Blob([new Uint8Array([1])], { type: "image/webp" }));
    putThumbnail.mockRejectedValue(new Error("boom"));
    const { result } = renderHook(() => usePdfUploads(), { wrapper });
    act(() => result.current.addFiles([pdf("a.pdf"), pdf("b.pdf")]));
    await act(async () => {
      pending[0]!.resolve({ item: item(null), created: true });
      pending[1]!.resolve({ item: { ...item(null), id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c" }, created: true });
      await flush();
    });
    expect(putThumbnail).toHaveBeenCalledTimes(1);
    expect(result.current.rows).toEqual([]);
    expect(toastsPushed).toEqual([]);
  });
});
