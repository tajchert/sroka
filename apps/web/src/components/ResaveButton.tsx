import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { findExtension, resaveWithExtension } from "../lib/extension.ts";
import { CheckIcon, PuzzleIcon } from "./StatusIcons.tsx";

export const RESAVE_LABEL = "Re-save with extension";
/** After the click the original is the active tab; these words live in the tooltip / aria-label only. */
const OPENED_AUTO = "Opened. Sroka saves the full page when it has loaded.";
const OPENED_CLICK = "Opened. Click the Sroka button on that page to save the full page.";

/**
 * "Preview only" banner action: renders nothing unless the Sroka extension is installed in this browser. The extension
 * opens the original in a new tab and that tab is saved with its rendered (signed-in) page: by itself when the extension
 * has host access to the site, else on the user's click on the Sroka button there (badge ↻). If the extension refuses
 * (signed out, another account), the original is opened as with "Open original".
 */
export function ResaveButton({ item }: { item: { id: string; url: string } }) {
  const [extId, setExtId] = useState<string | null>(null);
  const [state, setState] = useState<"idle" | "busy" | "auto" | "click">("idle");

  const qc = useQueryClient();
  const opened = state === "auto" || state === "click";

  // Back on this tab after the re-save: refetch the item (the app does not refetch on focus); a pending re-parse then
  // runs the reader's normal parse polling and the full text replaces the preview.
  useEffect(() => {
    if (!opened) return;
    const back = () => {
      if (document.visibilityState === "visible") void qc.invalidateQueries({ queryKey: ["item", item.id] });
    };
    document.addEventListener("visibilitychange", back);
    window.addEventListener("focus", back);
    return () => {
      document.removeEventListener("visibilitychange", back);
      window.removeEventListener("focus", back);
    };
  }, [opened, qc, item.id]);

  useEffect(() => {
    let live = true;
    void findExtension().then((id) => live && setExtId(id));
    return () => {
      live = false;
    };
  }, []);

  if (!extId) return null;

  const onClick = async () => {
    setState("busy");
    const r = await resaveWithExtension(extId, item);
    if (r.ok) return setState(r.auto ? "auto" : "click");
    setState("idle");
    window.open(item.url, "_blank", "noopener,noreferrer");
  };

  const label = state === "auto" ? OPENED_AUTO : state === "click" ? OPENED_CLICK : RESAVE_LABEL;
  return (
    <button
      type="button"
      className="inline-flex items-center gap-1.5 underline disabled:opacity-60"
      onClick={() => void onClick()}
      disabled={state === "busy"}
      title={label}
      aria-label={label}
    >
      {opened ? <CheckIcon size={14} /> : <PuzzleIcon size={14} />}
      <span aria-hidden>{RESAVE_LABEL}</span>
    </button>
  );
}
