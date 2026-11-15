import type { Item } from "@sroka/shared";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { placeholderItem } from "../lib/cache.ts";

const refresh = vi.fn();
vi.mock("../lib/hooks.ts", async (orig) => ({
  ...(await orig<typeof import("../lib/hooks.ts")>()),
  useItemActions: () => new Proxy({ refresh }, { get: (t, k) => (k in t ? t[k as "refresh"] : () => undefined) }),
  useParsePolling: () => undefined,
}));

import { ItemRow } from "./ItemRow.tsx";

const pdfItem = (over: Partial<Item> = {}): Item => ({
  ...placeholderItem("https://sroka.app/pdf/" + "a".repeat(64)),
  id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
  kind: "pdf",
  fileName: "paper.pdf",
  fileSize: 1000,
  title: "paper",
  siteName: "PDF",
  parseStatus: "ok",
  ...over,
});
const row = (item: Item) =>
  render(
    <MemoryRouter>
      <ItemRow item={item} onDomain={() => undefined} onTag={() => undefined} />
    </MemoryRouter>,
  );

describe("ItemRow PDF thumbnail", () => {
  it("shows the first-page preview with a PDF badge when the item has one", () => {
    const { container } = row(pdfItem({ leadImageUrl: "https://c.example/s/x/thumb.webp", leadImageKey: "thumb.webp" }));
    const img = container.querySelector("img");
    expect(img?.getAttribute("src")).toBe("https://c.example/s/x/thumb.webp");
    expect(img?.className).toContain("object-top");
    expect(screen.getByTestId("pdf-badge").textContent).toBe("PDF");
  });

  it("falls back to the PDF tile without a preview", () => {
    const { container } = row(pdfItem());
    expect(container.querySelector("img")).toBeNull();
    expect(screen.getByTestId("pdf-tile").textContent).toBe("PDF");
  });
});

describe("ItemRow statuses", () => {
  afterEach(() => {
    cleanup();
    refresh.mockClear();
  });
  const article = (over: Partial<Item> = {}): Item => ({
    ...placeholderItem("https://example.com/blog/why-sqlite-is-fast"),
    id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
    parseStatus: "ok",
    title: "Why SQLite is fast",
    excerpt: "An excerpt.",
    ...over,
  });

  it("pending: spinner tile, slug title, skeleton instead of the excerpt, no status words", () => {
    row(article({ id: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c", parseStatus: "pending", title: null, excerpt: null }));
    expect(screen.getByTestId("pending-tile").getAttribute("title")).toBe("Preparing…");
    expect(screen.getByRole("link", { name: "Why sqlite is fast" })).toBeTruthy();
    expect(screen.getByTestId("excerpt-skeleton")).toBeTruthy();
    expect(screen.queryByText("Fetching")).toBeNull();
  });

  it("failed: error badge, plain reason, and Open original + Retry without the menu", () => {
    row(article({ parseStatus: "failed", parseError: "http_404", excerpt: null }));
    expect(screen.getByRole("img", { name: "Couldn't save the text" })).toBeTruthy();
    expect(screen.getByText("The page is gone.")).toBeTruthy();
    expect(screen.queryByText("http_404")).toBeNull();
    const open = screen.getByRole("link", { name: "Open original" });
    expect(open.getAttribute("href")).toBe("https://example.com/blog/why-sqlite-is-fast");
    expect(open.getAttribute("target")).toBe("_blank");
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("keeps the row height stable: 2-line title clamp, two excerpt lines reserved, Open original inline only from sm up", () => {
    const { container } = row(article({ parseStatus: "failed", parseError: "http_404", excerpt: null }));
    expect(container.querySelector("h3")!.className).toContain("line-clamp-2");
    expect(container.querySelector("h3")!.className).toContain("min-w-0");
    // Reserved even with nothing to show (failed, no excerpt), so a status never changes the height.
    expect(container.querySelector(".min-h-\\[42px\\]")).toBeTruthy();
    // On a phone only Retry sits inline (Open original lives in the ⋯ menu), so the title keeps its width.
    const open = screen.getByRole("link", { name: "Open original" });
    expect(open.className).toContain("hidden");
    expect(open.className).toContain("sm:flex");
    expect(screen.getByRole("button", { name: "Retry" }).className).not.toContain("hidden");
  });

  it("⋯ button has the same 44px coarse-pointer hit area as the star and archive buttons, offset so the row height holds", () => {
    row(article());
    const more = screen.getByRole("button", { name: "More" });
    expect(more.className).toContain("size-[30px]");
    expect(more.className).toContain("pointer-coarse:size-11");
    // 44px box, 18px of negative margin: the same 26px of row height as the 30px button with its -mt-1.
    expect(more.className).toContain("pointer-coarse:-mt-[11px]");
    expect(more.className).toContain("pointer-coarse:-mb-[7px]");
  });

  it("failed with an unknown code shows no reason sentence and never the code", () => {
    const { container } = row(article({ parseStatus: "failed", parseError: "weird_internal" }));
    expect(container.textContent).not.toContain("weird_internal");
  });

  it("partial / paywalled: icon badges with the shared words, no text pills", () => {
    const { container, unmount } = row(article({ parseStatus: "partial" }));
    expect(screen.getByTestId("status-partial").getAttribute("title")).toBe("Partial copy");
    expect(container.textContent).not.toContain("Partial");
    unmount();
    row(article({ parseStatus: "partial", parseError: "paywalled" }));
    expect(screen.getByTestId("status-paywalled").getAttribute("aria-label")).toBe("Preview only");
  });

  it("ok rows have no status icons or retry buttons", () => {
    row(article());
    expect(screen.queryByTestId("status-failed")).toBeNull();
    expect(screen.queryByRole("button", { name: "Retry" })).toBeNull();
  });

  it("read rows show a muted check + Read, not a Done chip", () => {
    const { container } = row(article({ progress: 1 }));
    expect(screen.getByText("Read")).toBeTruthy();
    expect(screen.queryByText("Done")).toBeNull();
    expect(container.querySelector(".bg-tag")).toBeNull();
  });
});
