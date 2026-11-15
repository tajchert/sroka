import type { Item } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { pickNext } from "./nextItem.ts";

const it_ = (id: string, over: Partial<Item> = {}) => ({ id, status: "unread", parseStatus: "ok", ...over }) as Item;

describe("pickNext", () => {
  it("is the first other, unarchived item with a readable copy", () => {
    const items = [it_("cur"), it_("p", { parseStatus: "pending" }), it_("f", { parseStatus: "failed" }), it_("ar", { status: "archived" }), it_("tmp-1"), it_("hid"), it_("ok"), it_("later")];
    expect(pickNext(items, "cur", new Set(["hid"]))?.id).toBe("ok");
    expect(pickNext([it_("a", { parseStatus: "partial" })], "cur")?.id).toBe("a");
  });
  it("is null when nothing qualifies", () => {
    expect(pickNext([it_("cur")], "cur")).toBeNull();
    expect(pickNext([], "cur")).toBeNull();
  });
});
