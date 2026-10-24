import { describe, expect, it } from "vitest";
import { RunQueue } from "./runQueue.ts";

function harness(limit = 2) {
  const started: string[] = [];
  const done = new Map<string, () => void>();
  const q = new RunQueue(limit, (k) => new Promise<void>((res) => { started.push(k); done.set(k, res); }));
  const finish = async (k: string) => { done.get(k)!(); await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); };
  return { q, started, finish };
}

describe("RunQueue", () => {
  it("runs at most 2 at once and starts the next when one finishes", async () => {
    const { q, started, finish } = harness();
    expect(["a", "b", "c", "d"].map((k) => q.add(k))).toEqual([true, true, false, false]);
    expect(started).toEqual(["a", "b"]);
    await finish("a");
    expect(started).toEqual(["a", "b", "c"]);
    await finish("b");
    expect(started).toEqual(["a", "b", "c", "d"]);
  });

  it("removes a waiting job and re-adding (retry) goes to the back", async () => {
    const { q, started, finish } = harness();
    ["a", "b", "c"].forEach((k) => q.add(k));
    expect(q.remove("c")).toBe(true);
    expect(q.remove("a")).toBe(false); // already running
    q.add("c");
    await finish("a");
    expect(started).toEqual(["a", "b", "c"]);
  });

  it("a failing job still frees its slot", async () => {
    const started: string[] = [];
    const q = new RunQueue(1, async (k) => { started.push(k); if (k === "a") throw new Error("x"); });
    q.add("a");
    q.add("b");
    await new Promise((r) => setTimeout(r, 0));
    expect(started).toEqual(["a", "b"]);
  });
});
