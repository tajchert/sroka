import type { Item } from "@sroka/shared";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { placeholderItem } from "../lib/cache.ts";

vi.mock("../lib/hooks.ts", async (orig) => ({
  ...(await orig<typeof import("../lib/hooks.ts")>()),
  useItemActions: () => new Proxy({}, { get: () => () => undefined }),
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
