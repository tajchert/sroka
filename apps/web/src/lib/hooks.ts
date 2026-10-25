import { useQueryClient } from "@tanstack/react-query";
import type { Item, UpdateItemRequest } from "@sroka/shared";
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { ApiRequestError, POLL_GIVE_UP_MS, api, pollDelay } from "./api.ts";
import { patchItem, placeholderItem, prependItem, removeItem, replaceItem } from "./cache.ts";
import { hideItem, unhideItem, useToasts } from "./store.tsx";

export const itemTitle = (i: Item) => i.title || i.fileName || i.siteName || hostOf(i.canonicalUrl || i.url);
export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function errMessage(e: unknown): string {
  if (e instanceof ApiRequestError) {
    if (e.code === "invalid_url") return "That does not look like a web address.";
    if (e.status === 429) return "Too many requests. Try again shortly.";
    return e.message === e.code ? "Something went wrong. Try again." : e.message;
  }
  return "Could not reach Sroka. Check your connection.";
}

/** Mutations on items with cache patching, error toasts and a 6 s undo window for deletes. */
interface PendingDelete {
  run: () => Promise<void>;
  cancel: () => void;
}
const pendingDeletes = new Set<PendingDelete>();
/** Sign-out: run deletes the user already confirmed (while the session is still valid). */
export async function flushPendingDeletes(): Promise<void> {
  const all = [...pendingDeletes];
  pendingDeletes.clear();
  await Promise.all(all.map((p) => p.run()));
}
/** Session lost (401): drop queued deletes so they cannot hit the next session. */
export function cancelPendingDeletes(): void {
  const all = [...pendingDeletes];
  pendingDeletes.clear();
  for (const p of all) p.cancel();
}

export function useItemActions() {
  const qc = useQueryClient();
  const toasts = useToasts();

  const refreshCounts = useCallback(() => {
    void qc.invalidateQueries({ queryKey: ["me"] });
    void qc.invalidateQueries({ queryKey: ["tags"] });
  }, [qc]);

  const patch = useCallback(
    async (item: Item, body: UpdateItemRequest, optimistic?: Partial<Item>): Promise<Item | null> => {
      if (optimistic) patchItem(qc, { ...item, ...optimistic });
      try {
        const next = await api.updateItem(item.id, body);
        patchItem(qc, next);
        refreshCounts();
        return next;
      } catch (e) {
        patchItem(qc, item);
        toasts.push({ message: errMessage(e), tone: "error" });
        return null;
      }
    },
    [qc, toasts, refreshCounts],
  );

  const setArchived = useCallback(
    (item: Item, archived: boolean) =>
      patch(item, { status: archived ? "archived" : "unread" }, { status: archived ? "archived" : "unread" }).then((r) => {
        if (r) toasts.push({ message: archived ? "Archived" : "Moved to My List" });
        return r;
      }),
    [patch, toasts],
  );
  const toggleFavorite = useCallback(
    (item: Item) => patch(item, { isFavorite: !item.isFavorite }, { isFavorite: !item.isFavorite }),
    [patch],
  );
  const setTags = useCallback((item: Item, tags: string[]) => patch(item, { tags }, { tags }), [patch]);

  const remove = useCallback(
    (item: Item, onDone?: () => void) => {
      hideItem(item.id);
      let done = false;
      const entry: PendingDelete = {
        run: async () => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          pendingDeletes.delete(entry);
        try {
          await api.deleteItem(item.id);
          removeItem(qc, item.id);
          refreshCounts();
        } catch (e) {
          if (!(e instanceof ApiRequestError && e.status === 404)) toasts.push({ message: errMessage(e), tone: "error" });
          else removeItem(qc, item.id);
        } finally {
          unhideItem(item.id);
        }
        },
        cancel: () => {
          done = true;
          clearTimeout(timer);
          unhideItem(item.id);
        },
      };
      const timer = setTimeout(() => void entry.run(), 6000);
      pendingDeletes.add(entry);
      toasts.push(
        {
          message: "Deleted",
          actionLabel: "Undo",
          onAction: () => {
            pendingDeletes.delete(entry);
            entry.cancel();
          },
        },
        6000,
      );
      onDone?.();
    },
    [qc, toasts, refreshCounts],
  );

  const refresh = useCallback(
    async (item: Item) => {
      try {
        patchItem(qc, await api.refreshItem(item.id));
        void qc.invalidateQueries({ queryKey: ["content", item.id] });
        toasts.push({ message: "Fetching the page again" });
      } catch (e) {
        toasts.push({ message: errMessage(e), tone: "error" });
      }
    },
    [qc, toasts],
  );

  const add = useCallback(
    async (url: string): Promise<boolean> => {
      const trimmed = url.trim();
      if (!trimmed) return false;
      const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(trimmed) ? trimmed : `https://${trimmed}`;
      const temp = placeholderItem(withScheme);
      prependItem(qc, temp);
      try {
        const { item, created } = await api.createItem(withScheme);
        replaceItem(qc, temp.id, item);
        if (!created) toasts.push({ message: "Already saved. Moved to the top of My List." });
        refreshCounts();
        return true;
      } catch (e) {
        removeItem(qc, temp.id);
        toasts.push({ message: errMessage(e), tone: "error" });
        return false;
      }
    },
    [qc, toasts, refreshCounts],
  );

  return { setArchived, toggleFavorite, setTags, remove, refresh, add };
}

/**
 * Polls a pending item per api.md 5.1 (2 s, 4 s, 8 s ... capped at 30 s, give up after 5 min)
 * and patches the caches when it changes.
 */
export function useParsePolling(item: Item | undefined): { gaveUp: boolean } {
  const qc = useQueryClient();
  const pending = !!item && item.parseStatus === "pending" && !item.id.startsWith("tmp-");
  const id = item?.id;
  const [gaveUp, setGaveUp] = useState(false);
  useEffect(() => {
    if (!pending || !id) return;
    setGaveUp(false);
    const started = Date.now();
    let attempt = 0;
    let timer: ReturnType<typeof setTimeout>;
    let cancelled = false;
    const tick = async () => {
      if (cancelled) return;
      if (Date.now() - started > POLL_GIVE_UP_MS) {
        setGaveUp(true);
        return;
      }
      try {
        const next = await api.getItem(id);
        if (cancelled) return;
        patchItem(qc, next);
        if (next.parseStatus !== "pending") return;
      } catch {
        /* keep polling through transient errors */
      }
      timer = setTimeout(tick, pollDelay(attempt++));
    };
    timer = setTimeout(tick, pollDelay(attempt++));
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [pending, id, qc]);
  return { gaveUp };
}

/** True when the keyboard event target is a text field (shortcuts must not fire). */
export function isTyping(e: KeyboardEvent): boolean {
  const t = e.target as HTMLElement | null;
  return !!t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
}

/**
 * List keyboard shortcuts: j/k move the selection, Enter opens, a archives, f favourites.
 * Nothing is selected until the user presses j/k (a click opens the row instead);
 * `resetKey` clears the selection when the list changes.
 */
export function useListKeyboard(items: Item[], resetKey: string): [number, (i: number) => void] {
  const navigate = useNavigate();
  const actions = useItemActions();
  const [sel, setSel] = useState(-1);
  useEffect(() => setSel(-1), [resetKey]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e) || e.metaKey || e.ctrlKey || e.altKey) return;
      const cur = items[sel];
      const move = (n: number) => {
        const i = Math.max(0, Math.min(items.length - 1, n));
        setSel(i);
        document.querySelector(`[data-item-id="${items[i]?.id}"]`)?.scrollIntoView({ block: "nearest" });
      };
      switch (e.key) {
        case "j": move(sel + 1); break;
        case "k": move(sel - 1); break;
        case "Enter": if (cur && !(e.target as HTMLElement | null)?.closest?.("button,a") && !cur.id.startsWith("tmp-")) navigate(`/item/${cur.id}`); break;
        case "a": if (cur) void actions.setArchived(cur, cur.status !== "archived"); break;
        case "f": if (cur) void actions.toggleFavorite(cur); break;
        default: return;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [items, sel, actions, navigate]);
  return [sel, setSel];
}
