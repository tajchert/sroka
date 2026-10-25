import { type QueryClient, useQueryClient } from "@tanstack/react-query";
import { useCallback, useRef, useState } from "react";
import { RunQueue } from "./runQueue.ts";
import type { Item } from "@sroka/shared";
import { api } from "./api.ts";
import { patchItem, promoteItem } from "./cache.ts";
import { reportClientError } from "./error-reporting.ts";
import { renderPdfThumbnail } from "./pdf-thumb.ts";
import { UploadError, checkFiles, checkMessages, mapUploadError, uploadPdf, type UploadHandle } from "./pdf.ts";
import { useToasts } from "./store.tsx";

export interface UploadRow {
  key: string;
  name: string;
  size: number;
  loaded: number;
  state: "queued" | "uploading" | "processing" | "error";
  error?: string;
}

export const MAX_CONCURRENT_UPLOADS = 2;

/** Best-effort first-page preview of a just-uploaded PDF; never reaches the user (api.md §5.9). */
async function addPreview(qc: QueryClient, file: File, item: Item): Promise<void> {
  if (item.leadImageKey) return; // a duplicate that already has one
  const image = await renderPdfThumbnail(file);
  if (!image) return;
  try {
    patchItem(qc, await api.putThumbnail(item.id, image));
  } catch (e) {
    reportClientError(e, "pdf thumbnail upload");
  }
}

/** Upload queue for PDFs: validates, uploads at most 2 at a time (the rest wait), tracks per-file rows. */
export function usePdfUploads() {
  const qc = useQueryClient();
  const toasts = useToasts();
  const [rows, setRows] = useState<UploadRow[]>([]);
  const files = useRef(new Map<string, File>());
  const handles = useRef(new Map<string, UploadHandle>());

  const queue = useRef<RunQueue | null>(null);

  const patchRow = (key: string, patch: Partial<UploadRow>) => setRows((r) => r.map((x) => (x.key === key ? { ...x, ...patch } : x)));
  const dropRow = (key: string) => {
    queue.current?.remove(key);
    files.current.delete(key);
    handles.current.delete(key);
    setRows((r) => r.filter((x) => x.key !== key));
  };

  const run = useCallback(
    async (key: string) => {
      const file = files.current.get(key);
      if (!file) return;
      patchRow(key, { state: "uploading", loaded: 0, error: undefined });
      const h = uploadPdf(file, (loaded, total) => patchRow(key, { loaded, state: loaded >= total ? "processing" : "uploading" }));
      handles.current.set(key, h);
      try {
        const { item, created } = await h.promise;
        promoteItem(qc, item);
        void qc.invalidateQueries({ queryKey: ["me"] });
        void qc.invalidateQueries({ queryKey: ["tags"] });
        if (!created) toasts.push({ message: "Already saved. Moved to the top of My List." });
        dropRow(key);
        void addPreview(qc, file, item);
      } catch (e) {
        const error = e instanceof UploadError ? e.message : mapUploadError({ status: 0, code: "network" });
        if (e instanceof UploadError && e.failure.code === "aborted") dropRow(key);
        else patchRow(key, { state: "error", error });
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [qc, toasts],
  );

  const getQueue = () => (queue.current ??= new RunQueue(MAX_CONCURRENT_UPLOADS, (k) => runRef.current(k)));
  const runRef = useRef(run);
  runRef.current = run;
  const enqueue = (key: string) => {
    patchRow(key, { state: "queued", loaded: 0, error: undefined });
    getQueue().add(key);
  };

  const addFiles = useCallback(
    (list: Iterable<File>) => {
      const check = checkFiles(list);
      for (const m of checkMessages(check)) toasts.push({ message: m, tone: "error" });
      for (const f of check.accepted) {
        const key = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        files.current.set(key, f);
        setRows((r) => [...r, { key, name: f.name, size: f.size, loaded: 0, state: "queued" }]);
        getQueue().add(key);
      }
    },
    [toasts],
  );

  return {
    rows,
    addFiles,
    retry: (key: string) => enqueue(key),
    dismiss: (key: string) => {
      handles.current.get(key)?.abort();
      dropRow(key);
    },
  };
}
