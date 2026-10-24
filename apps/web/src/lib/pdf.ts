/** PDF upload helpers (docs/superpowers/specs/2026-10-24-pdf-upload-design.md). Pure pieces are unit-tested. */
import { CreateItemResponse, LIMITS, type CreateItemResponse as CreateItemResponseT } from "@sroka/shared";

export const MAX_PDF_BYTES = LIMITS.maxPdfBytes;

export function formatSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let v = bytes / 1024;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return `${v >= 10 ? Math.round(v) : v.toFixed(1)} ${units[u]}`;
}

/** `#page=` fragment for the browser viewer: progressAnchor is a 0-based page index. */
export function pageFragment(anchor: number | null | undefined): string {
  return typeof anchor === "number" && Number.isInteger(anchor) && anchor >= 0 ? `#page=${anchor + 1}` : "";
}

export function isPdfFile(f: { name: string; type: string }): boolean {
  return f.type === "application/pdf" || (f.type === "" && /\.pdf$/i.test(f.name));
}

export interface FileCheck {
  accepted: File[];
  notPdf: File[];
  tooLarge: File[];
}

/** Split dropped/picked files: non-PDFs are ignored, PDFs over the limit rejected. */
export function checkFiles(files: Iterable<File>, maxBytes = MAX_PDF_BYTES): FileCheck {
  const out: FileCheck = { accepted: [], notPdf: [], tooLarge: [] };
  for (const f of files) {
    if (!isPdfFile(f)) out.notPdf.push(f);
    else if (f.size > maxBytes) out.tooLarge.push(f);
    else out.accepted.push(f);
  }
  return out;
}

/** Toast messages for a check result (empty array when all fine). */
export function checkMessages(c: FileCheck, maxBytes = MAX_PDF_BYTES): string[] {
  const msgs: string[] = [];
  if (c.notPdf.length) msgs.push(c.notPdf.length === 1 ? `Ignored ${c.notPdf[0]!.name}: only PDF files can be added.` : `Ignored ${c.notPdf.length} files that are not PDFs.`);
  if (c.tooLarge.length) {
    const limit = formatSize(maxBytes);
    msgs.push(c.tooLarge.length === 1 ? `${c.tooLarge[0]!.name} is too large (${formatSize(c.tooLarge[0]!.size)}). The limit is ${limit}.` : `${c.tooLarge.length} files are over the ${limit} limit.`);
  }
  return msgs;
}

export function buildUploadUrl(name: string, tags: string[] = []): string {
  const sp = new URLSearchParams();
  sp.set("name", name);
  for (const t of tags) sp.append("tag", t);
  sp.set("source", "web");
  return `/v1/items/pdf?${sp.toString()}`;
}

export interface UploadFailure {
  status: number; // 0 = network
  code: string;
}

/** User-facing message for an upload failure (413, 415, 409 storage_full, 411, offline, ...). */
export function mapUploadError(f: UploadFailure): string {
  if (f.status === 0) return "Could not reach Sroka. Check your connection and try again.";
  if (f.status === 413) return `This file is over the ${formatSize(MAX_PDF_BYTES)} limit.`;
  if (f.status === 415) return "This file does not look like a PDF.";
  if (f.status === 409 && f.code === "storage_full") return "Your PDF storage is full. Delete some PDFs to add more.";
  if (f.status === 401) return "You were signed out. Sign in again.";
  if (f.status === 429) return "Too many requests. Try again shortly.";
  if (f.status === 400 || f.status === 411) return "This file could not be uploaded.";
  return "Upload failed. Try again.";
}

export interface UploadHandle {
  promise: Promise<CreateItemResponseT>;
  abort: () => void;
}

export class UploadError extends Error {
  constructor(public failure: UploadFailure) {
    super(mapUploadError(failure));
    this.name = "UploadError";
  }
}

/** XHR upload with progress (fetch cannot report upload progress). Sends the raw bytes. */
export function uploadPdf(file: File, onProgress: (loaded: number, total: number) => void, tags: string[] = []): UploadHandle {
  const xhr = new XMLHttpRequest();
  const promise = new Promise<CreateItemResponseT>((resolve, reject) => {
    xhr.open("POST", buildUploadUrl(file.name, tags));
    xhr.withCredentials = true;
    xhr.setRequestHeader("Content-Type", "application/pdf");
    xhr.setRequestHeader("X-Sroka-Device", "web");
    xhr.setRequestHeader("Accept", "application/json");
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) onProgress(e.loaded, e.total);
    };
    xhr.onerror = () => reject(new UploadError({ status: 0, code: "network" }));
    xhr.onabort = () => reject(new UploadError({ status: 0, code: "aborted" }));
    xhr.onload = () => {
      let data: unknown = null;
      try {
        data = xhr.responseText ? JSON.parse(xhr.responseText) : null;
      } catch {
        /* non-JSON */
      }
      if (xhr.status >= 200 && xhr.status < 300) {
        const parsed = CreateItemResponse.safeParse(data);
        if (parsed.success) resolve(parsed.data);
        else reject(new UploadError({ status: 500, code: "bad_response" }));
      } else {
        const code = (data as { error?: string } | null)?.error ?? `http_${xhr.status}`;
        reject(new UploadError({ status: xhr.status, code }));
      }
    };
    xhr.send(file);
  });
  return { promise, abort: () => xhr.abort() };
}
