import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router";
import { ApiRequestError, api } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";

export default function Tags() {
  const qc = useQueryClient();
  const toasts = useToasts();
  const tags = useQuery({ queryKey: ["tags"], queryFn: api.listTags });
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState("");

  const done = () => {
    void qc.invalidateQueries({ queryKey: ["tags"] });
    void qc.invalidateQueries({ queryKey: ["items"] });
  };
  const rename = async (id: string) => {
    const next = name.trim();
    setEditing(null);
    if (!next) return;
    try {
      await api.renameTag(id, next);
      toasts.push({ message: "Tag renamed" });
      done();
    } catch (e) {
      toasts.push({ message: e instanceof ApiRequestError && e.status === 400 ? "That tag name is not valid." : "Could not rename the tag.", tone: "error" });
    }
  };
  const remove = async (id: string, tag: string) => {
    if (!confirm(`Delete the tag "${tag}"? Items keep everything else.`)) return;
    try {
      await api.deleteTag(id);
      toasts.push({ message: "Tag deleted" });
      done();
    } catch {
      toasts.push({ message: "Could not delete the tag.", tone: "error" });
    }
  };

  return (
    <div className="mx-auto max-w-2xl px-4 py-6 sm:px-8">
      <h1 className="text-3xl font-extrabold tracking-tight">Tags</h1>
      <p className="mt-2 text-sm text-ink2">Renaming to an existing tag merges the two.</p>
      {tags.isPending ? (
        <div className="flex justify-center py-16"><span className="spinner" /></div>
      ) : tags.data?.length ? (
        <ul className="mt-6">
          {tags.data.map((t) => (
            <li key={t.id} className="flex items-center gap-3 border-b border-rule py-3">
              {editing === t.id ? (
                <form className="flex flex-1 gap-2" onSubmit={(e) => { e.preventDefault(); void rename(t.id); }}>
                  <input className="input !py-1" autoFocus aria-label={`New name for ${t.name}`} value={name} onChange={(e) => setName(e.target.value)} maxLength={64} />
                  <button className="btn btn-primary">Save</button>
                  <button type="button" className="btn" onClick={() => setEditing(null)}>Cancel</button>
                </form>
              ) : (
                <>
                  <Link to={`/tag/${encodeURIComponent(t.name)}`} className="flex-1 font-medium hover:underline">{t.name}</Link>
                  <span className="text-sm text-ink2">{t.count} {t.count === 1 ? "item" : "items"}</span>
                  <button className="btn" onClick={() => { setEditing(t.id); setName(t.name); }}>Rename</button>
                  <button className="btn btn-danger" onClick={() => void remove(t.id, t.name)}>Delete</button>
                </>
              )}
            </li>
          ))}
        </ul>
      ) : (
        <p className="py-16 text-center text-ink2">No tags yet. Add tags to an item from the library or the reader.</p>
      )}
    </div>
  );
}
