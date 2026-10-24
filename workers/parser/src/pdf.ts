/**
 * PDF jobs (`ParseJob.pdf`, spec docs/superpowers/specs/2026-10-24-pdf-upload-design.md "Parser"):
 * read document.pdf from R2, extract metadata + text with unpdf, write text.txt. Never fetches the URL, never
 * touches document.pdf or the shared D1 cache. Extraction problems are `status: "ok"` + an error code (the item
 * stays readable); only R2 read failures throw TransientError (retry).
 */
import { log, PARSER_VERSION, PDF_FILE, r2Keys, readingMinutes, type ParseJob, type ParseResult } from "@sroka/shared";
import { getDocumentProxy } from "unpdf";
import type { ParserEnv } from "./env.ts";
import {
  capUtf8,
  TEXT_FILE,
  cleanPdfLang,
  cleanPdfString,
  cleanPdfTitle,
  normalizePdfText,
  PDF_MAX_PAGES,
  PDF_MAX_TEXT_BYTES,
  pdfExcerpt,
  wordCountOf,
} from "./pdf-text.ts";
import { failedResult, TransientError, type JobStats } from "./process.ts";


type PdfCode = "pdf_no_text" | "pdf_encrypted" | "pdf_extract_failed";

interface Extraction {
  text: string;
  info: Record<string, unknown>;
  pages: number;
}

function okResult(job: ParseJob, over: Partial<ParseResult>): ParseResult {
  return {
    status: "ok",
    parseGen: job.parseGen,
    contentId: job.pdf!.contentId,
    contentPrivate: true,
    title: null,
    excerpt: null,
    siteName: "PDF",
    author: null,
    lang: null,
    wordCount: null,
    readingMinutes: null,
    parserVersion: PARSER_VERSION,
    ...over,
  };
}

async function extract(data: Uint8Array): Promise<Extraction> {
  const pdf = await getDocumentProxy(data);
  try {
    let info: Record<string, unknown> = {};
    try {
      const meta = await pdf.getMetadata();
      info = (meta?.info ?? {}) as Record<string, unknown>;
    } catch {
      // metadata is optional
    }
    const limit = Math.min(pdf.numPages, PDF_MAX_PAGES);
    const parts: string[] = [];
    let size = 0;
    for (let i = 1; i <= limit && size < PDF_MAX_TEXT_BYTES; i++) {
      const page = await pdf.getPage(i);
      const tc = await page.getTextContent();
      let line = "";
      for (const it of tc.items as Array<{ str?: string; hasEOL?: boolean }>) {
        if (typeof it.str !== "string") continue;
        line += it.str;
        if (it.hasEOL) line += "\n";
      }
      page.cleanup();
      parts.push(line);
      size += line.length; // chars >= bytes/4; the exact byte cap is applied by capUtf8
    }
    return { text: parts.join("\n\n"), info, pages: pdf.numPages };
  } finally {
    await pdf.loadingTask.destroy().catch(() => {});
  }
}

export async function processPdfJob(
  env: ParserEnv,
  job: ParseJob,
  stillWanted?: () => Promise<boolean>,
  stats: JobStats = {},
): Promise<ParseResult | null> {
  const contentId = job.pdf!.contentId;
  stats.method = "pdf";
  stats.fallbackOutcome = "none";
  const dir = r2Keys.contentDir(contentId, job.userId);

  let data: Uint8Array;
  try {
    const obj = await env.CONTENT.get(dir + PDF_FILE);
    if (!obj) {
      stats.errorDetail = "pdf_object_missing";
      return failedResult(job, "pdf_missing");
    }
    data = new Uint8Array(await obj.arrayBuffer());
  } catch (e) {
    throw new TransientError(`R2 read failed: ${e instanceof Error ? e.message : String(e)}`);
  }
  stats.bytes = data.byteLength;

  const noText = (code: PdfCode, detail?: string): ParseResult => {
    stats.errorDetail = detail ?? code;
    return okResult(job, { error: code });
  };

  let ex: Extraction;
  try {
    ex = await extract(data);
  } catch (e) {
    const name = e instanceof Error ? e.name : "";
    const encrypted = name === "PasswordException" || /password/i.test(e instanceof Error ? e.message : "");
    log.warn("pdf extraction failed", { event: encrypted ? "pdf_encrypted" : "pdf_extract_failed", itemId: job.itemId, errorName: name });
    return noText(encrypted ? "pdf_encrypted" : "pdf_extract_failed", name || "unknown");
  }

  const capped = capUtf8(normalizePdfText(ex.text));
  const text = new TextDecoder().decode(capped.bytes);
  const words = wordCountOf(text);
  stats.textChars = text.length;
  if (words === 0) {
    stats.errorDetail = "pdf_no_text";
    return okResult(job, { error: "pdf_no_text" });
  }

  if (stillWanted && !(await stillWanted())) return null;
  try {
    await env.CONTENT.put(dir + TEXT_FILE, capped.bytes, { httpMetadata: { contentType: "text/plain; charset=utf-8" } });
  } catch (e) {
    // best effort (spec): the original stays readable without text.txt
    log.warnException("pdf text.txt write failed", e, { event: "pdf_text_write_failed", itemId: job.itemId });
  }
  return okResult(job, {
    title: cleanPdfTitle(ex.info.Title),
    author: cleanPdfString(ex.info.Author),
    lang: cleanPdfLang(ex.info.Language),
    excerpt: pdfExcerpt(text),
    wordCount: words,
    readingMinutes: readingMinutes(words),
  });
}
