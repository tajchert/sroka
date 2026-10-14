import { cancelPendingDeletes } from "../lib/hooks.ts";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { NavLink, Outlet, useLocation } from "react-router";
import { api, setUnauthorizedHandler } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";
import SignIn from "../routes/SignIn.tsx";
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

const linkCls = ({ isActive }: { isActive: boolean }) =>
  `flex items-center justify-between rounded-lg px-3 py-1.5 text-[0.95rem] ${isActive ? "bg-paper2 font-semibold text-ink" : "text-ink2 hover:bg-paper2 hover:text-ink"}`;

export default function Shell() {
  const qc = useQueryClient();
  const loc = useLocation();
  const [open, setOpen] = useState(false);
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
  const nav = (
    <nav className="flex h-full flex-col gap-6 overflow-y-auto p-4" aria-label="Library">
      <NavLink to="/" className="px-2 pt-1 pb-2" end>
        <Wordmark />
      </NavLink>
      <div className="flex flex-col gap-0.5">
        <NavLink to="/" end className={linkCls}>
          My List <span className="text-xs text-ink2">{stats.unread}</span>
        </NavLink>
        <NavLink to="/archive" className={linkCls}>
          Archive <span className="text-xs text-ink2">{stats.archived}</span>
        </NavLink>
        <NavLink to="/favorites" className={linkCls}>
          Favorites <span className="text-xs text-ink2">{stats.favorites}</span>
        </NavLink>
        <NavLink to="/all" className={linkCls}>
          All
        </NavLink>
      </div>
      <div className="flex min-h-0 flex-col gap-0.5">
        <div className="flex items-center justify-between px-3 pb-1">
          <span className="text-sm font-semibold">Tags</span>
          <NavLink to="/tags" end className="text-xs text-ink2 hover:text-ink hover:underline">
            Manage
          </NavLink>
        </div>
        {tags.data?.length === 0 && <p className="px-3 text-sm text-ink2">No tags yet.</p>}
        {tags.data?.map((t) => (
          <NavLink key={t.id} to={`/tag/${encodeURIComponent(t.name)}`} className={linkCls}>
            <span className="truncate">{t.name}</span> <span className="text-xs text-ink2">{t.count}</span>
          </NavLink>
        ))}
      </div>
      <div className="mt-auto flex flex-col gap-0.5 border-t border-rule pt-3">
        <NavLink to="/settings" className={linkCls}>
          Settings
        </NavLink>
        <p className="truncate px-3 pt-1 text-xs text-ink2">{me.data.user.email}</p>
      </div>
    </nav>
  );

  return (
    <div className="flex h-full">
      <aside className="hidden w-64 shrink-0 border-r border-rule md:block">{nav}</aside>
      {open && (
        <div className="fixed inset-0 z-40 md:hidden">
          <button className="absolute inset-0 bg-black/40" aria-label="Close menu" onClick={() => setOpen(false)} />
          <aside className="absolute inset-y-0 left-0 w-72 bg-paper shadow-xl">{nav}</aside>
        </div>
      )}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 border-b border-rule px-4 py-2.5 md:hidden">
          <button className="btn" onClick={() => setOpen(true)} aria-label="Open menu">
            Menu
          </button>
          <Wordmark />
        </header>
        <main className="min-h-0 flex-1 overflow-y-auto" id="scroll-root">
          <Outlet />
        </main>
      </div>
      <Toasts />
    </div>
  );
}
