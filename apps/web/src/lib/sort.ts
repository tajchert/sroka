import type { ItemSort } from "@sroka/shared";
import { useCallback, useState } from "react";

/** Which list a sort choice belongs to; each list remembers its own sort. */
export type SortList = "unread" | "archived" | "favorites" | "all" | "tag" | "search";

export interface SortOption {
  value: ItemSort;
  label: string;
}

const GENERAL: SortOption[] = [
  { value: "newest", label: "Newest first" },
  { value: "oldest", label: "Oldest first" },
  { value: "shortest", label: "Shortest read" },
];
const ARCHIVE: SortOption[] = [
  { value: "archived", label: "Recently archived" },
  { value: "oldest", label: "Oldest first" },
  { value: "shortest", label: "Shortest read" },
];

export const sortOptions = (list: SortList): SortOption[] => (list === "archived" ? ARCHIVE : GENERAL);

const storageKey = (list: SortList) => `sroka.sort.${list}`;

function readSort(list: SortList): ItemSort {
  const opts = sortOptions(list);
  try {
    const v = localStorage.getItem(storageKey(list));
    const hit = opts.find((o) => o.value === v);
    if (hit) return hit.value;
  } catch {
    // storage unavailable (private mode): fall back to the default
  }
  return opts[0]!.value;
}

/** The sort of one list, remembered per list in localStorage. */
export function useListSort(list: SortList): [ItemSort, (s: ItemSort) => void] {
  const [state, setState] = useState(() => ({ list, sort: readSort(list) }));
  const sort = state.list === list ? state.sort : readSort(list);
  const set = useCallback(
    (s: ItemSort) => {
      setState({ list, sort: s });
      try {
        localStorage.setItem(storageKey(list), s);
      } catch {
        // ignore
      }
    },
    [list],
  );
  return [sort, set];
}
