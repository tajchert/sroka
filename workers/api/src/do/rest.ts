/** Translation of REST convenience requests into sync ops (api.md §5.4, D5 single mutation path). */
import { type Op, type UpdateItemRequest, tagKey, uuidv7 } from "@sroka/shared";
import type { ItemData } from "./rows.ts";

/**
 * PATCH /v1/items/:id body → ops. `current` is the live item (for the tag diff and progress-only-anchor).
 * All ops share `at`; opIds are fresh server uuidv7s.
 */
export function patchToOps(patch: UpdateItemRequest, current: ItemData, at: number, newId: () => string = uuidv7): Op[] {
  const itemId = current.id;
  const ops: Op[] = [];
  if (patch.status !== undefined) ops.push({ opId: newId(), at, type: "item.setStatus", itemId, status: patch.status });
  if (patch.isFavorite !== undefined) ops.push({ opId: newId(), at, type: "item.setFavorite", itemId, value: patch.isFavorite });
  if (patch.title !== undefined) ops.push({ opId: newId(), at, type: "item.setTitle", itemId, title: patch.title });
  if (patch.progress !== undefined || patch.progressAnchor !== undefined) {
    ops.push({
      opId: newId(),
      at,
      type: "item.setProgress",
      itemId,
      progress: patch.progress ?? current.progress,
      anchor: patch.progressAnchor ?? null,
    });
  }
  if (patch.tags !== undefined) {
    const want = new Map<string, string>();
    for (const t of patch.tags) if (!want.has(tagKey(t))) want.set(tagKey(t), t);
    const have = new Set(current.tags.map(tagKey));
    // Removals first so a full replacement never trips the per-item tag limit.
    for (const name of current.tags) {
      if (!want.has(tagKey(name))) ops.push({ opId: newId(), at, type: "item.tag", itemId, tag: name, present: false });
    }
    for (const [key, name] of want) {
      if (!have.has(key)) ops.push({ opId: newId(), at, type: "item.tag", itemId, tag: name, present: true });
    }
  }
  return ops;
}
