import { cancelPendingDeletes } from "../lib/hooks.ts";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { NavLink, Outlet, useLocation, useNavigate } from "react-router";
import { api, setUnauthorizedHandler } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";
import SignIn from "../routes/SignIn.tsx";
import { isTyping } from "../lib/hooks.ts";
import { Wordmark } from "./Logo.tsx";

function Toasts() {
  const { toasts, dismiss } = useToasts();
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-4 z-50 flex flex-col items-center gap-2 px-4" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div
          key={t.id}
          className={`pointer-events-auto flex items-center gap-4 rounded-full px-5 py-2.5 text-sm shadow-lg ${t.tone === "error" ? "bg-[#c2362f] text-white" : "bg-ink text-paper"}`}
        >
          <span>{t.message}</span>
          {t.actionLabel && (
            <button
              type="button"
              className="cursor-pointer font-semibold underline"
              onClick={() => {
                t.onAction?.();
                dismiss(t.id);
              }}
            >
              {t.actionLabel}
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

const navCls = ({ isActive }: { isActive: boolean }) =>
  `group/nav flex h-9 items-center gap-2.5 rounded-[9px] px-2.5 text-sm hover:bg-paper3 hover:text-ink ${isActive ? "bg-paper3 font-semibold text-ink" : "text-ink2"}`;
const footCls = ({ isActive }: { isActive: boolean }) =>
  `flex h-[34px] items-center rounded-[9px] px-2.5 text-sm hover:bg-paper3 hover:text-ink ${isActive ? "bg-paper3 text-ink" : "text-ink2"}`;

function NavItem({ to, label, count, onClick }: { to: string; label: string; count?: number; onClick: () => void }) {
  return (
    <NavLink to={to} end className={navCls} onClick={onClick}>
      {({ isActive }) => (
        <>
          <span aria-hidden className={`-ml-1.5 h-4 w-[3px] rounded-sm ${isActive ? "bg-wing" : ""}`} />
          <span className="flex-1">{label}</span>
          {count !== undefined && <span className="font-mono text-[11px] font-normal text-ink3">{count}</span>}
        </>
      )}
    </NavLink>
  );
}

/**
 * Global search box. Typing (debounced) shows /search?q=…; clearing returns to the list you came from.
 */
function SearchBox({ inputRef, lastList }: { inputRef?: React.RefObject<HTMLInputElement | null>; lastList: React.RefObject<string> }) {
  const loc = useLocation();
  const navigate = useNavigate();
  const onSearch = loc.pathname === "/search";
  const urlQ = onSearch ? (new URLSearchParams(loc.search).get("q") ?? "") : "";
  const [value, setValue] = useState(urlQ);

  // follow the URL (back/forward, leaving search) unless it only differs by what is still being typed
  useEffect(() => {
    setValue((v) => (v.trim() === urlQ.trim() ? v : urlQ));
  }, [urlQ]);

  useEffect(() => {
    const q = value.trim();
    if (q === urlQ.trim()) return;
    const t = setTimeout(() => {
      if (q) navigate(`/search?q=${encodeURIComponent(q)}`, { replace: onSearch });
      else if (onSearch) navigate(lastList.current, { replace: true });
    }, 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  const clear = () => {
    setValue("");
    if (onSearch) navigate(lastList.current, { replace: true });
    inputRef?.current?.focus();
  };

  return (
    <div className="relative min-w-0 grow md:grow-0">
      <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden className="pointer-events-none absolute top-[11px] left-[11px] text-ink3">
        <circle cx="11" cy="11" r="6.5" fill="none" stroke="currentColor" strokeWidth="2" />
        <path d="M16 16l4.5 4.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      </svg>
      <input
        ref={inputRef}
        type="search"
        aria-label="Search your library"
        placeholder="Search"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Escape" && value) {
            e.preventDefault();
            clear();
          }
        }}
        className="h-[38px] w-full rounded-[10px] border-[1.5px] border-rule bg-paper pr-[34px] pl-[33px] text-sm text-ink outline-none placeholder:text-ink3 focus:border-wing [&::-webkit-search-cancel-button]:hidden"
      />
      {value ? (
        <button
          type="button"
          title="Clear search"
          aria-label="Clear search"
          onClick={clear}
          className="absolute top-[7px] right-1.5 flex size-6 cursor-pointer items-center justify-center rounded-md text-base leading-none text-ink2 hover:bg-paper3 hover:text-ink"
        >
          ×
        </button>
      ) : (
        <kbd aria-hidden className="pointer-events-none absolute top-[9px] right-[9px] hidden rounded-[5px] border border-rule2 px-1.5 py-px font-mono text-[11px] text-ink3 md:block">
          /
        </kbd>
      )}
    </div>
  );
}

export default function Shell() {
  const qc = useQueryClient();
  const loc = useLocation();
  const [open, setOpen] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const mobileSearchRef = useRef<HTMLInputElement>(null);
  const lastList = useRef("/");
  if (loc.pathname !== "/search") lastList.current = loc.pathname + loc.search;
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull, retry: false, staleTime: 60_000 });
  const tags = useQuery({ queryKey: ["tags"], queryFn: api.listTags, enabled: !!me.data, staleTime: 30_000 });

  useEffect(() => {
    setUnauthorizedHandler(() => {
      cancelPendingDeletes();
      qc.clear();
      qc.setQueryData(["me"], null);
    });
    return () => setUnauthorizedHandler(null);
  }, [qc]);
  useEffect(() => setOpen(false), [loc.pathname, loc.search]);
  // "/" focuses the search box (whichever one is visible)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "/" || isTyping(e) || e.metaKey || e.ctrlKey || e.altKey) return;
      const el = [searchRef.current, mobileSearchRef.current].find((i) => i && i.offsetParent !== null) ?? searchRef.current;
      if (!el) return;
      e.preventDefault();
      el.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (me.isPending) {
    return (
      <div className="flex h-full items-center justify-center">
        <span className="spinner" aria-label="Loading" />
      </div>
    );
  }
  if (me.isError) {
    return (
      <div className="mx-auto flex h-full max-w-sm flex-col items-center justify-center gap-4 px-6 text-center">
        <Wordmark />
        <p className="text-ink2">Sroka could not be reached. Check your connection.</p>
        <button className="btn btn-primary" onClick={() => void me.refetch()}>
          Try again
        </button>
      </div>
    );
  }
  if (!me.data) return <><SignIn /><Toasts /></>;

  const stats = me.data.stats;
  // Clicking the link of the page already shown scrolls it back to the top (and closes the mobile menu).
  const toTopIfCurrent = (to: string) => () => {
    if (decodeURIComponent(loc.pathname) !== decodeURIComponent(to)) return;
    setOpen(false);
    document.getElementById("scroll-root")?.scrollTo({ top: 0, behavior: "smooth" });
  };
  const email = me.data.user.email;
  const isAdmin = me.data.isAdmin;
  const nav = (withSearch: boolean) => (
    <nav className="flex h-full flex-col gap-[22px] overflow-y-auto px-3.5 pt-[18px] pb-4" aria-label="Library">
      <NavLink to="/" end className="px-2 py-1" onClick={toTopIfCurrent("/")}>
        <Wordmark />
      </NavLink>
      {withSearch && <SearchBox inputRef={searchRef} lastList={lastList} />}
      <div className="flex flex-col gap-0.5">
        <NavItem to="/" label="My List" count={stats.unread} onClick={toTopIfCurrent("/")} />
        <NavItem to="/archive" label="Archive" count={stats.archived} onClick={toTopIfCurrent("/archive")} />
        <NavItem to="/favorites" label="Favorites" count={stats.favorites} onClick={toTopIfCurrent("/favorites")} />
        <NavItem to="/all" label="All" count={stats.unread + stats.archived} onClick={toTopIfCurrent("/all")} />
      </div>
      <div className="flex flex-col gap-2.5 px-2.5">
        <div className="flex items-baseline justify-between">
          <span className="text-[11px] font-medium tracking-[.1em] text-ink2 uppercase">Tags</span>
          <NavLink to="/tags" end className="text-xs text-link hover:text-ink">
            Manage
          </NavLink>
        </div>
        {tags.data?.length === 0 && <p className="text-xs text-ink3">No tags yet.</p>}
        <div className="flex flex-wrap gap-1.5">
          {tags.data?.map((t) => {
            const to = `/tag/${encodeURIComponent(t.name)}`;
            return (
              <NavLink
                key={t.id}
                to={to}
                title={`${t.count} ${t.count === 1 ? "item" : "items"}`}
                onClick={toTopIfCurrent(to)}
                className={({ isActive }) =>
                  `rounded-full px-2.5 py-1 text-xs ${isActive ? "bg-[#1e6f8f] text-[#f6f5f1]" : "bg-paper3 text-ink2 hover:bg-tag hover:text-tagink"}`
                }
              >
                {t.name}
              </NavLink>
            );
          })}
        </div>
      </div>
      <div className="mt-auto flex flex-col gap-0.5 border-t border-rule pt-3">
        <NavLink to="/settings" className={footCls}>
          Settings
        </NavLink>
        {isAdmin && (
          <NavLink to="/admin" className={footCls}>
            Admin
          </NavLink>
        )}
        <div className="flex items-center gap-2 px-2.5 pt-2">
          <span aria-hidden className="flex size-[22px] shrink-0 items-center justify-center rounded-full bg-tag text-[11px] font-semibold text-tagink">
            {email.charAt(0).toUpperCase()}
          </span>
          <span className="truncate text-xs text-ink3">{email}</span>
        </div>
      </div>
    </nav>
  );

  return (
    <div className="flex h-full">
      <aside className="hidden w-[232px] shrink-0 border-r border-rule bg-paper2 md:block">{nav(true)}</aside>
      {open && (
        <div className="fixed inset-0 z-40 md:hidden">
          <button className="absolute inset-0 bg-black/40" aria-label="Close menu" onClick={() => setOpen(false)} />
          <aside className="absolute inset-y-0 left-0 w-72 bg-paper2 shadow-xl">{nav(false)}</aside>
        </div>
      )}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 border-b border-rule bg-paper2 px-3 py-2.5 md:hidden">
          <button
            className="flex size-[38px] shrink-0 cursor-pointer items-center justify-center rounded-[10px] text-ink2 hover:bg-paper3 hover:text-ink"
            onClick={() => setOpen(true)}
            aria-label="Open menu"
          >
            <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden>
              <path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </button>
          <SearchBox inputRef={mobileSearchRef} lastList={lastList} />
        </header>
        <main className="min-h-0 flex-1 overflow-y-auto" id="scroll-root">
          <Outlet />
        </main>
      </div>
      <Toasts />
    </div>
  );
}
