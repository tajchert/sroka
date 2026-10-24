import { describe, expect, it } from "vitest";
import { capUtf8, cleanPdfLang, cleanPdfString, cleanPdfTitle, normalizePdfText, pdfExcerpt, wordCountOf } from "../src/pdf-text.ts";

describe("cleanPdfTitle", () => {
  it("keeps a real title", () => expect(cleanPdfTitle("  Attention   Is All You Need ")).toBe("Attention Is All You Need"));
  it("strips Office prefix and extension", () => {
    expect(cleanPdfTitle("Microsoft Word - Quarterly report.docx")).toBe("Quarterly report");
    expect(cleanPdfTitle("Microsoft PowerPoint - deck.pptx")).toBe("deck");
  });
  it("rejects empty, generic and path-like titles", () => {
    for (const t of ["", "   ", "Untitled", "untitled document", "Microsoft Word - Document1", "PowerPoint Presentation", "C:\\Users\\a\\x.docx", "/home/a/x.tex", "file:///tmp/a.pdf", "x", null, 5]) {
      expect(cleanPdfTitle(t)).toBeNull();
    }
  });
  it("truncates very long titles", () => expect(cleanPdfTitle("a ".repeat(300))!.length).toBeLessThanOrEqual(200));
});

describe("text helpers", () => {
  it("cleans author and lang", () => {
    expect(cleanPdfString(" Jane\u0000 Doe ")).toBe("Jane Doe");
    expect(cleanPdfString("unknown")).toBeNull();
    expect(cleanPdfLang("en_US")).toBe("en-US");
    expect(cleanPdfLang("English")).toBeNull();
  });
  it("normalizes text, counts words, builds excerpt", () => {
    const t = normalizePdfText("a  b\r\n\r\n\r\n\r\nc \u00a0 d\n");
    expect(t).toBe("a b\n\nc d");
    expect(wordCountOf(t)).toBe(4);
    expect(wordCountOf("  ")).toBe(0);
    expect(pdfExcerpt("short text")).toBe("short text");
    expect(pdfExcerpt("   ")).toBeNull();
    const long = pdfExcerpt("word ".repeat(200))!;
    expect(long.length).toBeLessThanOrEqual(301);
    expect(long.endsWith("…")).toBe(true);
  });
  it("caps utf-8 on a code point boundary", () => {
    const r = capUtf8("ąę".repeat(10), 5);
    expect(r.truncated).toBe(true);
    expect(new TextDecoder().decode(r.bytes)).toBe("ąę");
    expect(new TextDecoder().decode(r.bytes)).not.toContain("\ufffd");
  });
});
