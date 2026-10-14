/** Tiny shared UI state: toasts (with optional action) and ids hidden while a delete can still be undone. */
import { createContext, useCallback, useContext, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";

export interface Toast {
  id: number;
  message: string;
  actionLabel?: string;
  onAction?: () => void;
  tone?: "info" | "error";
}

interface ToastApi {
  toasts: Toast[];
  push: (t: Omit<Toast, "id">, ttl?: number) => number;
  dismiss: (id: number) => void;
}

const Ctx = createContext<ToastApi | null>(null);
let nextId = 1;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const dismiss = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  const push = useCallback(
    (t: Omit<Toast, "id">, ttl = 5000) => {
      const id = nextId++;
      setToasts((list) => [...list.slice(-3), { ...t, id }]);
      setTimeout(() => dismiss(id), ttl);
      return id;
    },
    [dismiss],
  );
  const value = useMemo(() => ({ toasts, push, dismiss }), [toasts, push, dismiss]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useToasts(): ToastApi {
  const v = useContext(Ctx);
  if (!v) throw new Error("ToastProvider missing");
  return v;
}

// --- ids hidden while a delete is pending (undo window) ---
let hidden: ReadonlySet<string> = new Set();
const listeners = new Set<() => void>();
function setHidden(next: Set<string>) {
  hidden = next;
  listeners.forEach((l) => l());
}
export function hideItem(id: string) {
  setHidden(new Set(hidden).add(id));
}
export function unhideItem(id: string) {
  const n = new Set(hidden);
  n.delete(id);
  setHidden(n);
}
export function useHiddenIds(): ReadonlySet<string> {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => hidden,
  );
}
