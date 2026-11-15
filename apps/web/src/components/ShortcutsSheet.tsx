import { useEffect, useRef } from "react";
import { LIST_SHORTCUTS, READER_SHORTCUTS, type Shortcut } from "../lib/shortcuts.ts";

/**
 * Modal list of the keyboard shortcuts. Esc, `?`, the backdrop or the close button dismiss it; Tab stays inside
 * (the close button is the only control); focus returns to where it was.
 */
export function ShortcutsSheet({ onClose }: { onClose: () => void }) {
  const closeRef = useRef<HTMLButtonElement>(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    const before = document.activeElement as HTMLElement | null;
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" || (e.key === "?" && !e.metaKey && !e.ctrlKey && !e.altKey)) {
        e.preventDefault();
        e.stopPropagation(); // the reader's own Esc (back) must not also fire
        onCloseRef.current();
      } else if (e.key === "Tab") {
        e.preventDefault();
        closeRef.current?.focus();
      } else {
        e.stopPropagation(); // modal: no background shortcut (list keys, "/" search) may run behind the sheet
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      before?.focus?.();
    };
  }, []);

  return (
    <>
      <div aria-hidden data-testid="shortcuts-backdrop" className="fixed inset-0 z-40 bg-[rgb(10_11_14/.45)]" onClick={onClose} />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="shortcuts-title"
        className="fixed top-1/2 left-1/2 z-41 flex max-h-[calc(100dvh-32px)] w-[min(420px,calc(100vw-32px))] -translate-x-1/2 -translate-y-1/2 flex-col gap-4 overflow-y-auto rounded-2xl border border-rule2 bg-paper3 p-4 shadow-[0_18px_50px_rgb(0_0_0/.5)]"
      >
        <div className="flex items-center justify-between pl-1">
          <h2 id="shortcuts-title" className="text-[15px] font-semibold">Keyboard shortcuts</h2>
          <button
            ref={closeRef}
            type="button"
            title="Close (Esc)"
            aria-label="Close"
            onClick={onClose}
            className="flex size-8 cursor-pointer items-center justify-center rounded-lg text-ink2 hover:bg-paper hover:text-ink pointer-coarse:size-11"
          >
            <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden>
              <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </button>
        </div>
        <div className="grid gap-x-6 gap-y-4 sm:grid-cols-2">
          <Group title="Reading" rows={READER_SHORTCUTS} />
          <Group title="List" rows={LIST_SHORTCUTS} />
        </div>
      </div>
    </>
  );
}

function Group({ title, rows }: { title: string; rows: Shortcut[] }) {
  return (
    <section aria-label={title} className="flex flex-col gap-1.5">
      <div className="pl-1 text-[11px] font-medium tracking-[.1em] text-ink3 uppercase">{title}</div>
      <dl className="flex flex-col">
        {rows.map((r) => (
          <div key={r.keys} className="flex items-center justify-between gap-3 rounded-lg px-1 py-1.5 text-sm">
            <dt className="text-ink2">{r.label}</dt>
            <dd>
              <kbd className="inline-flex min-w-6 items-center justify-center rounded-md border border-rule2 bg-paper px-1.5 py-0.5 font-mono text-xs text-ink">{r.keys}</kbd>
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
