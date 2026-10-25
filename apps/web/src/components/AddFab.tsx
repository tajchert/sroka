import { useEffect, useRef, useState } from "react";

// Floating "Add" button: opens a popup to paste a link; PDF upload hides in the popup's "⋯" menu.
export function AddFab({ onAdd, onPickPdf }: { onAdd: (url: string) => Promise<boolean>; onPickPdf: () => void }) {
  const [open, setOpen] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [adding, setAdding] = useState(false);
  const fabRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const close = () => {
    setOpen(false);
    setMenuOpen(false);
    fabRef.current?.focus();
  };

  useEffect(() => {
    if (!open) return;
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      if (menuOpen) setMenuOpen(false);
      else close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, menuOpen]);

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
          <div aria-hidden className="fixed inset-0 z-30 bg-[rgb(10_11_14/.35)]" onClick={close} />
          <div
            role="dialog"
            aria-label="Add to My List"
            className="fixed right-4 bottom-[96px] left-4 z-30 flex flex-col gap-3 rounded-2xl border border-rule bg-paper2 px-3.5 pt-3.5 pb-4 shadow-[0_18px_50px_rgb(0_0_0/.5)] sm:left-auto sm:right-8 sm:bottom-[104px] sm:w-[420px]"
          >
            <div className="relative flex items-center justify-between pl-1.5">
              <h2 className="text-[15px] font-semibold">Add to My List</h2>
              <button
                type="button"
                title="More options"
                aria-label="More options"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                onClick={() => setMenuOpen((v) => !v)}
                className={`flex size-8 cursor-pointer items-center justify-center gap-[3px] rounded-lg text-ink2 hover:bg-paper3 hover:text-ink ${menuOpen ? "bg-paper3" : ""}`}
              >
                <span className="size-1 rounded-full bg-current" />
                <span className="size-1 rounded-full bg-current" />
                <span className="size-1 rounded-full bg-current" />
              </button>
              {menuOpen && (
                <div role="menu" className="menu top-[38px] right-0">
                  <button
                    type="button"
                    role="menuitem"
                    className="menu-item !flex-col !items-start !gap-0.5"
                    onClick={() => {
                      setOpen(false);
                      setMenuOpen(false);
                      onPickPdf();
                    }}
                  >
                    <span>Upload PDF…</span>
                    <span className="text-xs text-ink3">From your computer</span>
                  </button>
                </div>
              )}
            </div>
            <form onSubmit={submit} className="flex flex-col gap-3">
              <input
                ref={inputRef}
                className="input !h-11 !border-rule2 !px-3.5 !text-[15px] focus:!border-wing"
                type="text"
                inputMode="url"
                aria-label="Page address"
                placeholder="Paste a link"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
              />
              <div className="flex justify-end gap-2">
                <button type="button" className="h-[38px] cursor-pointer rounded-full px-4 text-sm text-ink2 hover:text-ink" onClick={close}>
                  Cancel
                </button>
                <button
                  className={`flex h-[38px] cursor-pointer items-center gap-2 rounded-full bg-ink px-5 text-sm font-semibold text-paper ${url.trim() || adding ? "" : "opacity-55"}`}
                  disabled={adding || !url.trim()}
                >
                  {adding && <span aria-hidden className="size-3.5 animate-spin rounded-full border-2 border-paper/20 border-t-paper" />}
                  <span>{adding ? "Saving…" : "Save"}</span>
                </button>
              </div>
            </form>
          </div>
        </>
      )}
      <button
        ref={fabRef}
        type="button"
        aria-expanded={open}
        aria-haspopup="dialog"
        className="fixed right-4 bottom-6 z-30 flex h-14 cursor-pointer items-center gap-2 rounded-full bg-ink pr-6 pl-[18px] text-base font-semibold text-paper shadow-[0_8px_24px_rgb(0_0_0/.45)] hover:bg-ink/90 sm:right-8 sm:bottom-8"
        onClick={() => (open ? close() : setOpen(true))}
      >
        <span aria-hidden className={`block text-[26px] leading-none font-normal transition-transform duration-150 ${open ? "rotate-45" : ""}`}>
          +
        </span>
        <span>{open ? "Close" : "Add"}</span>
      </button>
    </>
  );
}
