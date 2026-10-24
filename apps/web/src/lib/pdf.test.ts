import { describe, expect, it } from "vitest";
import { MAX_PDF_BYTES, buildUploadUrl, checkFiles, checkMessages, formatSize, mapUploadError, pageFragment } from "./pdf.ts";

const file = (name: string, type: string, size = 10) => {
  const f = new File(["x"], name, { type });
  Object.defineProperty(f, "size", { value: size });
  return f;
};

describe("checkFiles", () => {
  it("splits pdf, non-pdf and oversized", () => {
    const c = checkFiles([file("a.pdf", "application/pdf"), file("b.png", "image/png"), file("c.pdf", "application/pdf", MAX_PDF_BYTES + 1), file("d.PDF", "")]);
    expect(c.accepted.map((f) => f.name)).toEqual(["a.pdf", "d.PDF"]);
    expect(c.notPdf.map((f) => f.name)).toEqual(["b.png"]);
    expect(c.tooLarge.map((f) => f.name)).toEqual(["c.pdf"]);
  });
  it("accepts exactly the limit", () => {
    expect(checkFiles([file("a.pdf", "application/pdf", MAX_PDF_BYTES)]).accepted).toHaveLength(1);
  });
  it("messages", () => {
    const c = checkFiles([file("b.png", "image/png"), file("c.pdf", "application/pdf", MAX_PDF_BYTES + 1)]);
    const m = checkMessages(c);
    expect(m).toHaveLength(2);
    expect(m[0]).toContain("b.png");
    expect(m[1]).toContain("50 MB");
    expect(checkMessages(checkFiles([file("a.pdf", "application/pdf")]))).toEqual([]);
  });
});

describe("mapUploadError", () => {
  it("maps statuses", () => {
    expect(mapUploadError({ status: 413, code: "payload_too_large" })).toContain("limit");
    expect(mapUploadError({ status: 415, code: "unsupported_media_type" })).toContain("PDF");
    expect(mapUploadError({ status: 409, code: "storage_full" })).toContain("storage");
    expect(mapUploadError({ status: 0, code: "network" })).toContain("connection");
    expect(mapUploadError({ status: 500, code: "x" })).toContain("failed");
  });
});

describe("buildUploadUrl", () => {
  it("encodes name and tags, source web", () => {
    expect(buildUploadUrl("My Paper & more.pdf", ["a", "b c"])).toBe("/v1/items/pdf?name=My+Paper+%26+more.pdf&tag=a&tag=b+c&source=web");
  });
});

describe("pageFragment", () => {
  it("is 1-based and empty without anchor", () => {
    expect(pageFragment(0)).toBe("#page=1");
    expect(pageFragment(4)).toBe("#page=5");
    expect(pageFragment(null)).toBe("");
    expect(pageFragment(-1)).toBe("");
  });
});

describe("formatSize", () => {
  it("formats", () => {
    expect(formatSize(500)).toBe("500 B");
    expect(formatSize(2.3 * 1024 * 1024)).toBe("2.3 MB");
    expect(formatSize(1024)).toBe("1.0 KB");
    expect(formatSize(50 * 1024 * 1024)).toBe("50 MB");
    expect(formatSize(3 * 1024 ** 3)).toBe("3.0 GB");
  });
});
