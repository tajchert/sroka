import type { Item } from "@sroka/shared";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { patchItem } from "../lib/cache.ts";
import { ApiRequestError, api } from "../lib/api.ts";
import { pageFragment } from "../lib/pdf.ts";

/** Fetch the signed PDF into a Blob and expose an object URL that is revoked on unmount. */
export function usePdfBlob(itemId: string, contentId: string | null | undefined) {
  const contentQ = useQuery({
    queryKey: ["content", itemId, contentId],
    queryFn: () => api.getContent(itemId),
    enabled: !!contentId,
    staleTime: Infinity,
    refetchOnReconnect: false,
    refetchOnWindowFocus: false,
    retry: false,
  });
  const documentUrl = contentQ.data?.documentUrl ?? null;
  const [state, setState] = useState<{ url: string | null; error: boolean }>({ url: null, error: false });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!documentUrl) return;
    let cancelled = false;
    let objectUrl: string | null = null;
    setState({ url: null, error: false });
    void (async () => {
      try {
        const res = await fetch(documentUrl, { credentials: "omit" });
        if (!res.ok) throw new ApiRequestError(res.status, `http_${res.status}`);
        const blob = new Blob([await res.blob()], { type: "application/pdf" });
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        setState({ url: objectUrl, error: false });
      } catch {
        if (!cancelled) setState({ url: null, error: true });
      }
    })();
    return () => {
      cancelled = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
    // documentUrl is re-signed on refetch; the blob is keyed by item/content, so only reload on retry or content change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contentId, attempt, !!documentUrl]);
  const error = state.error || contentQ.isError || (contentQ.isSuccess && !documentUrl);
  return { url: state.url, error, retry: () => { setAttempt((a) => a + 1); void contentQ.refetch(); } };
}

export function PdfViewer({ item, blobUrl, error, onRetry }: { item: Item; blobUrl: string | null; error: boolean; onRetry: () => void }) {
  const qc = useQueryClient();
  // Start page is fixed when the document first loads; later progress updates must not reload the frame.
  const startAnchor = useRef<number | null>(item.progressAnchor);
  const started = useRef(false);
  useEffect(() => {
    // Count the item as started (sets lastReadAt) when it is opened at 0 progress.
    if (!blobUrl || started.current || item.progress > 0) return;
    started.current = true;
    void api.updateItem(item.id, { progress: 0.01 }).then((it) => patchItem(qc, it), () => undefined);
  }, [blobUrl, item.id, item.progress, qc]);

  if (error) {
    return (
      <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-6 py-24 text-center">
        <h2 className="font-serif text-xl font-semibold">Could not load the PDF</h2>
        <p className="text-ink2">The saved file did not load. Check your connection and try again.</p>
        <button className="btn btn-primary" onClick={onRetry}>Try again</button>
      </div>
    );
  }
  if (!blobUrl) {
    return (
      <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-6 py-24 text-center">
        <span className="spinner" aria-hidden />
        <h2 className="font-serif text-xl font-semibold">Loading PDF</h2>
      </div>
    );
  }
  return <iframe title={item.fileName ?? item.title ?? "PDF"} src={`${blobUrl}${pageFragment(startAnchor.current)}`} className="h-full w-full border-0" />;
}
