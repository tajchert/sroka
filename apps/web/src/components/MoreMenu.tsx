import { useEffect, useRef, useState, type ReactNode } from "react";

/** "⋯" button with a popup menu (item row, reader toolbar). Escape closes, arrow keys move between entries. */
export function MoreMenu({ label = "More", className = "", children }: { label?: string; className?: string; children: (close: () => void) => ReactNode }) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const close = () => {
    setOpen(false);
    btnRef.current?.focus();
  };

  useEffect(() => {
    if (!open) return;
    menuRef.current?.querySelector<HTMLElement>("a,button")?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        setOpen(false);
        btnRef.current?.focus();
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const items = Array.from(menuRef.current?.querySelectorAll<HTMLElement>("a,button") ?? []);
        const i = items.indexOf(document.activeElement as HTMLElement);
        items[(i + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open]);

  return (
    <div className="relative" onClick={(e) => e.stopPropagation()}>
      <button
        ref={btnRef}
        type="button"
        title={label}
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className={`flex cursor-pointer items-center justify-center gap-[3px] hover:bg-paper3 hover:text-ink ${open ? "bg-paper3 text-ink" : "text-ink3"} ${className}`}
      >
        <span aria-hidden className="size-1 rounded-full bg-current" />
        <span aria-hidden className="size-1 rounded-full bg-current" />
        <span aria-hidden className="size-1 rounded-full bg-current" />
      </button>
      {open && (
        <>
          <div aria-hidden className="fixed inset-0 z-30 cursor-default" onClick={() => setOpen(false)} />
          <div ref={menuRef} role="menu" aria-label={label} className="menu top-full right-0 mt-1 min-w-[13rem]">
            {children(close)}
          </div>
        </>
      )}
    </div>
  );
}

/** Menu entry with an optional 16px icon (SVG children drawn in a 24-unit box). */
export function MenuItem({ icon, danger, onClick, children }: { icon?: ReactNode; danger?: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" role="menuitem" className={`menu-item ${danger ? "text-danger" : ""}`} onClick={onClick}>
      {icon && <MenuIcon>{icon}</MenuIcon>}
      {children}
    </button>
  );
}

export function MenuLink({ href, icon, download, onClick, children }: { href: string; icon?: ReactNode; download?: string; onClick?: () => void; children: ReactNode }) {
  return (
    <a role="menuitem" className="menu-item no-underline" href={href} download={download} target={download ? undefined : "_blank"} rel="noopener noreferrer" onClick={onClick}>
      {icon && <MenuIcon>{icon}</MenuIcon>}
      {children}
    </a>
  );
}

export const MenuSep = () => <div role="separator" className="mx-1.5 my-1 h-px bg-rule2" />;

function MenuIcon({ children }: { children: ReactNode }) {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden className="shrink-0 text-ink2">
      {children}
    </svg>
  );
}

export const ICONS = {
  external: <path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />,
  archive: <path d="M3.5 5h17v4h-17z M5 9v10h14V9 M10 13h4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" />,
  unarchive: <path d="M3.5 5h17v4h-17z M5 9v10h14V9 M12 17v-5M9.5 14.5L12 12l2.5 2.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" />,
  tag: (
    <>
      <path d="M3.5 11.5V3.5h8l9 9-8 8z" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" />
      <circle cx="8" cy="8" r="1.6" fill="currentColor" />
    </>
  ),
  trash: <path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />,
  refresh: <path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v4h-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />,
  download: <path d="M12 4v11M7.5 10.5L12 15l4.5-4.5M5 19.5h14" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />,
};

export function Star({ on }: { on: boolean }) {
  return (
    <polygon
      points="12,2.8 14.8,8.9 21.4,9.6 16.5,14.1 17.9,20.6 12,17.3 6.1,20.6 7.5,14.1 2.6,9.6 9.2,8.9"
      fill={on ? "#f2c84b" : "none"}
      stroke={on ? "#c99a1e" : "currentColor"}
      strokeWidth="1.8"
      strokeLinejoin="round"
    />
  );
}
