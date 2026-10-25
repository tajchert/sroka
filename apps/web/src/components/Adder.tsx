import { useEffect, useRef, useState } from "react";
import { formatSize } from "../lib/pdf.ts";
import { useItemActions } from "../lib/hooks.ts";
import { usePdfUploads } from "../lib/uploads.ts";
import { AddFab } from "./AddFab.tsx";

/** Everything for adding to the library: the Add FAB, the PDF picker, drag-and-drop anywhere, upload progress rows. */
export function Adder() {
  const actions = useItemActions();
  // PDF upload: picker + drag and drop anywhere on the page
  const uploads = usePdfUploads();
  const pickerRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const dragDepth = useRef(0);
  const hasFiles = (e: DragEvent) => !!e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files");
  useEffect(() => {
    const enter = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      dragDepth.current++;
      setDragging(true);
    };
    const over = (e: DragEvent) => {
      if (hasFiles(e)) e.preventDefault();
    };
    const leave = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      dragDepth.current = Math.max(0, dragDepth.current - 1);
      if (dragDepth.current === 0) setDragging(false);
    };
    const drop = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      dragDepth.current = 0;
      setDragging(false);
      uploads.addFiles(Array.from(e.dataTransfer?.files ?? []));
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  }, [uploads.addFiles]);

  return (
    <>
      <AddFab onAdd={actions.add} onPickPdf={() => pickerRef.current?.click()} />
      <input
        ref={pickerRef}
        type="file"
        accept="application/pdf,.pdf"
        multiple
        className="sr-only"
        tabIndex={-1}
        aria-hidden
        data-testid="pdf-picker"
        onChange={(e) => {
          uploads.addFiles(Array.from(e.target.files ?? []));
          e.target.value = "";
        }}
      />

      <div aria-live="polite" className="sr-only">{dragging ? "Drop PDF to save" : ""}</div>
      {dragging && (
        <div aria-hidden className="pointer-events-none fixed inset-0 z-50 flex items-center justify-center bg-paper/85 p-6 backdrop-blur-sm">
          <div className="flex h-full w-full items-center justify-center rounded-2xl border-2 border-dashed border-wing">
            <p className="text-2xl font-extrabold">Drop PDF to save</p>
          </div>
        </div>
      )}

      {uploads.rows.length > 0 && (
        <ul className="flex flex-col gap-2" aria-label="PDF uploads">
          {uploads.rows.map((r) => (
            <li key={r.key} className="rounded-lg border border-rule bg-paper2 px-3 py-2 text-sm">
              <div className="flex items-center justify-between gap-3">
                <span className="min-w-0 truncate font-medium">{r.name}</span>
                <span className="flex shrink-0 items-center gap-2 text-ink2">
                  {r.state === "queued" && "Waiting"}
                  {r.state === "uploading" && `${Math.round((r.loaded / Math.max(1, r.size)) * 100)}%`}
                  {r.state === "processing" && "Saving…"}
                  {r.state === "error" && (
                    <>
                      <button type="button" className="underline" onClick={() => uploads.retry(r.key)}>Retry</button>
                      <button type="button" className="underline" onClick={() => uploads.dismiss(r.key)}>Dismiss</button>
                    </>
                    )}
                    {r.state !== "error" && <button type="button" className="underline" onClick={() => uploads.dismiss(r.key)} aria-label={`Cancel upload of ${r.name}`}>Cancel</button>}
                  </span>
                </div>
                {r.state === "error" ? (
                  <p role="alert" className="mt-1 text-[#c2362f]">{r.error}</p>
                ) : (
                  <div
                    role="progressbar"
                    aria-label={`Uploading ${r.name}`}
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={Math.round((r.loaded / Math.max(1, r.size)) * 100)}
                    className="mt-1.5 h-1 overflow-hidden rounded bg-rule"
                  >
                    <div className="sheen-bg h-full" style={{ width: `${Math.min(100, (r.loaded / Math.max(1, r.size)) * 100)}%` }} />
                  </div>
                )}
                <span className="sr-only">{formatSize(r.size)}</span>
              </li>
            ))}
          </ul>
        )}
    </>
  );
}
