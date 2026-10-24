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
vi.mock("./store.tsx", () => ({ useToasts: () => ({ push: () => undefined }) }));

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
