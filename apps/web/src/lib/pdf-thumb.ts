/**
 * First-page preview of a PDF the user is uploading (docs/superpowers/specs/2026-10-25-pdf-preview-design.md).
 * pdf.js is loaded on demand, only when a PDF is added. Best effort: any failure (encrypted, broken, timeout,
 * no canvas) resolves to null and the item keeps the PDF tile.
 */
export const THUMB_WIDTH = 480;
const MAX_HEIGHT = THUMB_WIDTH * 2;
const QUALITY = 0.75;
const TIMEOUT_MS = 10_000;

function toBlob(canvas: HTMLCanvasElement, type: string): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, type, QUALITY));
}

async function render(file: Blob): Promise<Blob | null> {
  const [pdfjs, worker] = await Promise.all([import("pdfjs-dist"), import("pdfjs-dist/build/pdf.worker.min.mjs?url")]);
  pdfjs.GlobalWorkerOptions.workerSrc = worker.default;
  const task = pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) });
  try {
    const doc = await task.promise;
    const page = await doc.getPage(1);
    const base = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: THUMB_WIDTH / base.width });
    const canvas = document.createElement("canvas");
    canvas.width = THUMB_WIDTH;
    canvas.height = Math.min(Math.ceil(viewport.height), MAX_HEIGHT); // taller pages: the bottom is cropped
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    ctx.fillStyle = "#fff"; // pages may be transparent
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    await page.render({ canvas, canvasContext: ctx, viewport }).promise;
    const webp = await toBlob(canvas, "image/webp");
    // Browsers that can't encode WebP (Safari) hand back PNG: re-encode as JPEG instead.
    return webp?.type === "image/webp" ? webp : await toBlob(canvas, "image/jpeg");
  } finally {
    void task.destroy();
  }
}

export async function renderPdfThumbnail(file: Blob): Promise<Blob | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), TIMEOUT_MS);
  });
  try {
    return await Promise.race([render(file).catch(() => null), timeout]);
  } finally {
    clearTimeout(timer);
  }
}
