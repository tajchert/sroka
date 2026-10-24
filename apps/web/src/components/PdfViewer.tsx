import type { Item } from "@sroka/shared";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { patchItem } from "../lib/cache.ts";
import { ApiRequestError, api } from "../lib/api.ts";
import { pageFragment } from "../lib/pdf.ts";

/**
 * Download the PDF from a signed URL. A 403 (expired signature) triggers exactly one re-sign via `resign`
 * (which returns a fresh URL) and a second attempt. With `fresh`, the URL is re-signed before the first attempt.
 */
export async function loadPdfBlob(opts: {
  url: string | null;
  fresh: boolean;
  resign: () => Promise<string | null>;
  fetchImpl?: typeof fetch;
}): Promise<Blob> {
  const doFetch = opts.fetchImpl ?? fetch;
  let url = opts.fresh || !opts.url ? await opts.resign() : opts.url;
  if (!url) throw new ApiRequestError(0, "no_document_url");
  let res = await doFetch(url, { credentials: "omit" });
  if (res.status === 403 && !opts.fresh) {
    url = await opts.resign();
    if (!url) throw new ApiRequestError(403, "http_403");
    res = await doFetch(url, { credentials: "omit" });
  }
  if (!res.ok) throw new ApiRequestError(res.status, `http_${res.status}`);
  return new Blob([await res.blob()], { type: "application/pdf" });
}

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
  const urlRef = useRef(documentUrl);
  urlRef.current = documentUrl;
  const refetchRef = useRef(contentQ.refetch);
  refetchRef.current = contentQ.refetch;
  const [state, setState] = useState<{ url: string | null; error: boolean }>({ url: null, error: false });
  const [attempt, setAttempt] = useState(0);
  const fresh = useRef(false);
  useEffect(() => {
    if (!contentId || (!documentUrl && !fresh.current)) return;
    let cancelled = false;
    let objectUrl: string | null = null;
    const forceFresh = fresh.current;
    fresh.current = false;
    setState({ url: null, error: false });
    void (async () => {
      try {
        const blob = await loadPdfBlob({
          url: urlRef.current,
          fresh: forceFresh,
          resign: async () => (await refetchRef.current()).data?.documentUrl ?? null,
        });
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
    // A re-signed documentUrl must not reload a displayed PDF, so the effect keys on retry/content/availability only.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contentId, attempt, !!documentUrl]);
  const error = state.error || contentQ.isError || (contentQ.isSuccess && !documentUrl);
  return {
    url: state.url,
    error,
    /** Re-sign first, then fetch the fresh URL. */
    retry: () => {
      fresh.current = true;
      setAttempt((a) => a + 1);
    },
  };
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
