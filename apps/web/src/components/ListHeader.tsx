import type { ItemSort } from "@sroka/shared";
import type { SortOption } from "../lib/sort.ts";
import { SortMenu } from "./SortMenu.tsx";

export function ListHeader({
  title,
  countLabel,
  sort,
  options,
  onSort,
}: {
  title: string;
  countLabel?: string;
  sort: ItemSort;
  options: SortOption[];
  onSort: (s: ItemSort) => void;
}) {
  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className="flex min-w-0 items-baseline gap-3">
        <h1 className="truncate text-[28px] font-extrabold tracking-[-.02em] sm:text-[34px]">{title}</h1>
        {countLabel && <span className="shrink-0 text-sm text-ink3">{countLabel}</span>}
      </div>
      <div className="flex-1" />
      <SortMenu value={sort} options={options} onChange={onSort} />
    </div>
  );
}

export const articles = (n: number) => `${n} ${n === 1 ? "article" : "articles"}`;
