import { useEffect, useRef } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { useItemActions } from "../lib/hooks.ts";
import { useToasts } from "../lib/store.tsx";

/** The first http(s) link in a share: the `url` field, else inside `text` (most Android apps), else `title`. */
export function sharedLink(params: URLSearchParams): string | null {
  for (const key of ["url", "text", "title"]) {
    const m = params.get(key)?.match(/https?:\/\/[^\s<>"']+/i);
    if (m) return m[0].replace(/[).,;:!?\]]+$/, "");
  }
  return null;
}

/**
 * PWA share target (`share_target` in manifest.webmanifest → GET /app/share?title&text&url). Saves the
 * shared link and opens My List, where it appears at the top. Signed out, the shell shows sign-in first
 * and this runs afterwards (the URL is kept).
 */
export default function Share() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const actions = useItemActions();
  const toasts = useToasts();
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const link = sharedLink(params);
    navigate("/", { replace: true });
    if (link) void actions.add(link);
    else toasts.push({ message: "There was no link to save in what you shared.", tone: "error" });
  }, [params, navigate, actions, toasts]);

  return (
    <div className="flex justify-center py-24">
      <span className="spinner" aria-label="Saving" />
    </div>
  );
}
