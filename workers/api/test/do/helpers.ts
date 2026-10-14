import { env } from "cloudflare:workers";
import { type OpInput, uuidv7 } from "@sroka/shared";
import type { Env } from "../../src/env.ts";

export const testEnv = env as unknown as Env;

let n = 0;
/** Fresh library stub per call (unique user id). */
export function freshLibrary(prefix = "u") {
  const userId = `${prefix}_${Date.now().toString(36)}_${++n}`;
  return { userId, lib: testEnv.LIBRARY.getByName(userId) };
}

export const T0 = 1_760_000_000_000;

export function add(itemId: string, url: string, at: number, extra: Partial<Extract<OpInput, { type: "item.add" }>> = {}): OpInput {
  return { opId: uuidv7(), type: "item.add", itemId, url, at, ...extra };
}
export function setStatus(itemId: string, status: "unread" | "archived", at: number): OpInput {
  return { opId: uuidv7(), type: "item.setStatus", itemId, status, at };
}
export function setFav(itemId: string, value: boolean, at: number): OpInput {
  return { opId: uuidv7(), type: "item.setFavorite", itemId, value, at };
}
export function tagOp(itemId: string, tag: string, present: boolean, at: number): OpInput {
  return { opId: uuidv7(), type: "item.tag", itemId, tag, present, at };
}
export function rename(from: string, to: string, at: number): OpInput {
  return { opId: uuidv7(), type: "tag.rename", from, to, at };
}
export function delTag(tag: string, at: number): OpInput {
  return { opId: uuidv7(), type: "tag.delete", tag, at };
}
export function delItem(itemId: string, at: number): OpInput {
  return { opId: uuidv7(), type: "item.delete", itemId, at };
}
