import { useEffect, useRef, useState } from "react";

// Floating "Save" button: opens a small popup to paste a link; PDF upload is a quiet secondary option.
export function AddFab({ onAdd, onPickPdf }: { onAdd: (url: string) => Promise<boolean>; onPickPdf: () => void }) {
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [adding, setAdding] = useState(false);
  const fabRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const close = () => {
    setOpen(false);
    fabRef.current?.focus();
  };

  useEffect(() => {
    if (!open) return;
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        close();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (adding || !url.trim()) return;
    setAdding(true);
    const ok = await onAdd(url);
    setAdding(false);
    if (ok) {
      setUrl("");
      close();
    }
  };

  return (
    <>
      {open && (
        <>
          <button type="button" aria-label="Close" tabIndex={-1} className="fixed inset-0 z-30 cursor-default bg-ink/10 sm:bg-transparent" onClick={close} />
          <div
            role="dialog"
            aria-label="Save a page"
            className="fixed inset-x-4 bottom-24 z-30 rounded-2xl border border-rule bg-paper p-4 shadow-xl sm:inset-x-auto sm:right-8 sm:w-[26rem]"
          >
            <form onSubmit={submit} className="flex gap-2">
              <input
                ref={inputRef}
                className="input"
                type="text"
                inputMode="url"
                aria-label="Page address"
                placeholder="Paste a link to save"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
              />
              <button className="btn btn-primary shrink-0" disabled={adding || !url.trim()}>
                {adding ? <span className="spinner" aria-label="Saving" /> : "Save"}
              </button>
            </form>
            <p className="mt-3 text-sm text-ink2">
              or{" "}
              <button
                type="button"
                className="cursor-pointer underline hover:text-ink"
                onClick={() => {
                  setOpen(false);
                  onPickPdf();
                }}
              >
                upload a PDF
              </button>
            </p>
          </div>
        </>
      )}
      <button
        ref={fabRef}
        type="button"
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={open ? "Close" : undefined}
        className={`btn btn-primary fixed right-4 bottom-6 z-30 !py-3 !text-base shadow-lg sm:right-8 ${open ? "!px-3" : "!px-5"}`}
        onClick={() => (open ? close() : setOpen(true))}
      >
        <svg aria-hidden width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
          <path d={open ? "M6 6l12 12M18 6L6 18" : "M12 5v14M5 12h14"} />
        </svg>
        {!open && "Save"}
      </button>
    </>
  );
}
