import { FetchError, safeFetch, type SafeFetchOptions } from "./safe-fetch.ts";

export const MAX_IMAGES = 50;
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
/**
 * Total bytes of stored images per article (memory budget for the 128 MB isolate: stored images are held
 * twice at the end — files + stored-level package.zip — next to up to `concurrency` in-flight downloads).
 */
export const MAX_TOTAL_IMAGE_BYTES = 16 * 1024 * 1024;
/** Largest original (untransformed) image kept when the Images transform fails. */
export const MAX_FALLBACK_IMAGE_BYTES = 2 * 1024 * 1024;

/** Injected by the worker (Cloudflare Images binding). Throw to signal failure (fallback to original is applied). */
export type ImageTransform = (bytes: Uint8Array, contentType: string, opts: { width: number }) => Promise<{ bytes: Uint8Array; contentType: string }>;

export interface StoredImage {
  /** Relative path in the content dir, e.g. img/{sha256}.webp */
  path: string;
  bytes: Uint8Array;
  contentType: string;
  sha256: string;
}

export interface ProcessedImages {
  /** original absolute URL -> stored image (only successfully processed images) */
  byUrl: Map<string, StoredImage>;
  /** unique stored files */
  files: StoredImage[];
  /** thumbnail (webp, 400px) of the lead image, if it could be produced */
  thumb: Uint8Array | null;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/avif": "avif", "image/bmp": "bmp" };

export interface ProcessImagesOptions {
  urls: string[];
  /** Candidate thumbnail source URLs, in preference order (e.g. og:image, then first article image). */
  leadCandidates: string[];
  transform: ImageTransform;
  fetchOptions: SafeFetchOptions;
  maxImages?: number;
  maxTotalBytes?: number;
  concurrency?: number;
}

/**
 * Download, convert (max width 1600 webp) and hash images. Never throws for per-image failures.
 * On transform failure the original is stored when it is a raster image of <= 2 MB (SVG is never stored).
 * Stops downloading once the per-article byte budget is spent.
 */
export async function processImages(o: ProcessImagesOptions): Promise<ProcessedImages> {
  const max = o.maxImages ?? MAX_IMAGES;
  const urls = o.urls.slice(0, max);
  const byUrl = new Map<string, StoredImage>();
  const files = new Map<string, StoredImage>();
  let thumb: Uint8Array | null = null;
  let thumbFrom: string | null = null;
  let totalBytes = 0;
  let exhausted = false;
  const budget = o.maxTotalBytes ?? MAX_TOTAL_IMAGE_BYTES;
  const leadSet = new Set(o.leadCandidates);

  const work = [...urls];
  // Lead image not part of the article: fetch only for the thumbnail.
  const leadOnly = o.leadCandidates.filter((u) => !urls.includes(u)).slice(0, 1);

  const one = async (url: string, isLeadOnly: boolean) => {
    let res: { bytes: Uint8Array; contentType: string } | null;
    try {
      res = await safeFetch(url, {
        ...o.fetchOptions,
        allow: ["image"],
        maxBytes: MAX_IMAGE_BYTES,
        timeoutMs: o.fetchOptions.timeoutMs ?? 15_000,
        accept: "image/avif,image/webp,image/*;q=0.8",
      });
    } catch (e) {
      if (e instanceof FetchError) return;
      return;
    }
    if (res.bytes.byteLength === 0) return;
    const ctype = res.contentType.split(";")[0]!.trim().toLowerCase();

    // Thumbnail from the best available lead candidate (earlier candidate wins).
    if (leadSet.has(url)) {
      const rank = o.leadCandidates.indexOf(url);
      const curRank = thumbFrom === null ? Infinity : o.leadCandidates.indexOf(thumbFrom);
      if (rank < curRank) {
        try {
          const t = await o.transform(res.bytes, ctype, { width: 400 });
          // re-check after the await: a higher-priority candidate may have finished meanwhile
          const cur = thumbFrom === null ? Infinity : o.leadCandidates.indexOf(thumbFrom);
          if (rank < cur) {
            thumb = t.bytes;
            thumbFrom = url;
          }
        } catch {
          /* no thumb from this one */
        }
      }
    }
    if (isLeadOnly) return;

    let stored: { bytes: Uint8Array; contentType: string; ext: string } | null = null;
    try {
      const t = await o.transform(res.bytes, ctype, { width: 1600 });
      stored = { bytes: t.bytes, contentType: t.contentType || "image/webp", ext: "webp" };
    } catch {
      const ext = EXT[ctype];
      if (ext && res.bytes.byteLength <= MAX_FALLBACK_IMAGE_BYTES) stored = { bytes: res.bytes, contentType: ctype, ext };
    }
    res = null; // release the download before hashing/storing
    if (!stored) return;
    if (totalBytes + stored.bytes.byteLength > budget) {
      exhausted = true; // over the per-article byte budget: skip, and stop downloading more
      return;
    }
    const sha256 = await sha256Hex(stored.bytes);
    const path = `img/${sha256}.${stored.ext}`;
    const img: StoredImage = { path, bytes: stored.bytes, contentType: stored.contentType, sha256 };
    if (!files.has(path)) totalBytes += stored.bytes.byteLength;
    files.set(path, img);
    byUrl.set(url, img);
  };

  const queue: Array<[string, boolean]> = [...work.map((u) => [u, false] as [string, boolean]), ...leadOnly.map((u) => [u, true] as [string, boolean])];
  const workers = Array.from({ length: Math.min(o.concurrency ?? 4, queue.length) }, async () => {
    for (;;) {
      if (exhausted || totalBytes >= budget) return; // budget spent: don't download the rest
      const next = queue.shift();
      if (!next) return;
      await one(next[0], next[1]);
    }
  });
  await Promise.all(workers);
  return { byUrl, files: [...files.values()], thumb };
}
