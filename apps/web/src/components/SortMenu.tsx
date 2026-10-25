import type { ItemSort } from "@sroka/shared";
import { useEffect, useRef, useState } from "react";
import type { SortOption } from "../lib/sort.ts";

export function SortMenu({ value, options, onChange }: { value: ItemSort; options: SortOption[]; onChange: (s: ItemSort) => void }) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const current = options.find((o) => o.value === value) ?? options[0]!;

  useEffect(() => {
    if (!open) return;
    menuRef.current?.querySelector<HTMLButtonElement>('[aria-checked="true"]')?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        setOpen(false);
        btnRef.current?.focus();
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const items = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>("button") ?? []);
        const i = items.indexOf(document.activeElement as HTMLButtonElement);
        items[(i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open]);

  return (
    <div className="relative">
      <button
        ref={btnRef}
        type="button"
        title="Sort"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className={`flex h-[38px] cursor-pointer items-center gap-2 rounded-[10px] border-[1.5px] pr-2.5 pl-3 text-sm whitespace-nowrap text-ink hover:bg-paper3 ${open ? "border-wing bg-paper3" : "border-rule bg-paper2"}`}
      >
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden className="text-ink2">
          <path d="M7 4v16M7 20l-3.5-3.5M7 20l3.5-3.5M17 20V4M17 4l-3.5 3.5M17 4l3.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span>{current.label}</span>
        <svg viewBox="0 0 24 24" width="14" height="14" aria-hidden className="text-ink3">
          <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      {open && (
        <>
          <div aria-hidden className="fixed inset-0 z-30" onClick={() => setOpen(false)} />
          <div ref={menuRef} role="menu" aria-label="Sort by" className="menu top-11 right-0">
            <div className="px-2.5 pt-2 pb-1.5 text-[11px] font-medium tracking-[.1em] text-ink3 uppercase">Sort by</div>
            {options.map((o) => {
              const on = o.value === current.value;
              return (
                <button
                  key={o.value}
                  type="button"
                  role="menuitemradio"
                  aria-checked={on}
                  className={`menu-item ${on ? "font-semibold" : "text-ink2"}`}
                  onClick={() => {
                    onChange(o.value);
                    setOpen(false);
                    btnRef.current?.focus();
                  }}
                >
                  <span aria-hidden className="w-3.5 text-link">{on ? "✓" : ""}</span>
                  <span>{o.label}</span>
                </button>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}
