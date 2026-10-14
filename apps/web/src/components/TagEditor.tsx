import { normalizeTagName, tagKey } from "@sroka/shared";
import { useQuery } from "@tanstack/react-query";
import { useId, useState } from "react";
import { api } from "../lib/api.ts";

/** Chip editor. Commits the whole set via onChange (server replaces the tag set). */
export function TagEditor({ tags, onChange }: { tags: string[]; onChange: (tags: string[]) => void }) {
  const [draft, setDraft] = useState("");
  const listId = useId();
  const all = useQuery({ queryKey: ["tags"], queryFn: api.listTags, staleTime: 30_000 });

  const add = (raw: string) => {
    const name = normalizeTagName(raw);
    setDraft("");
    if (!name || name.length > 64) return;
    if (tags.some((t) => tagKey(t) === tagKey(name))) return;
    onChange([...tags, name]);
  };

  return (
    <div className="flex flex-wrap items-center gap-1.5">
      {tags.map((t) => (
        <span key={t} className="chip">
          {t}
          <button
            type="button"
            aria-label={`Remove tag ${t}`}
            className="cursor-pointer leading-none text-ink2 hover:text-ink"
            onClick={() => onChange(tags.filter((x) => x !== t))}
          >
            ×
          </button>
        </span>
      ))}
      <input
        list={listId}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            add(draft);
          } else if (e.key === "Backspace" && !draft && tags.length) onChange(tags.slice(0, -1));
        }}
        onBlur={() => draft && add(draft)}
        placeholder={tags.length ? "Add tag" : "Add tags"}
        aria-label="Add tag"
        className="min-w-24 flex-1 bg-transparent py-0.5 text-sm outline-none placeholder:text-ink2"
      />
      <datalist id={listId}>
        {(all.data ?? []).map((t) => (
          <option key={t.id} value={t.name} />
        ))}
      </datalist>
    </div>
  );
}
