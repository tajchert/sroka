/**
 * Convergence fuzz: ops from 3 simulated devices (each device's own ops stay in its order; devices are
 * interleaved randomly, pushed in random batch sizes) must produce the same library state in every order.
 *
 * Op generation follows what real clients can produce: a device only references seed items/tags it
 * pulled before going offline, or items/tags it created itself. Duplicate URLs across devices (aliases),
 * LWW fields, pair LWW, and stale item.tag ops vs later tag rename / merge / delete are all exercised.
 */
import { type OpInput, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { T0, add, freshLibrary } from "./helpers.ts";

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SEED_TAGS = ["alpha", "beta", "gamma", "delta", "eps"];
const SHARED_URLS = ["https://shared.example/p0", "https://shared.example/p1?utm_source=a", "https://shared.example/p1", "https://shared.example/p2"];

interface Scenario {
  seed: OpInput[];
  devices: { id: string; ops: OpInput[] }[];
}

function makeScenario(rnd: () => number): Scenario {
  const pick = <T,>(xs: readonly T[]): T => xs[Math.floor(rnd() * xs.length)]!;
  const seedIds = Array.from({ length: 6 }, () => uuidv7());
  const seed: OpInput[] = seedIds.map((id, i) =>
    add(id, `https://seed.example/s${i}`, T0 + i, { tags: SEED_TAGS.filter(() => rnd() < 0.5) }),
  );
  const deletable = seedIds.slice(4);
  const editable = seedIds.slice(0, 4);
  const devices = ["devA", "devB", "devC"].map((dev) => {
    const ops: OpInput[] = [];
    const own: string[] = [];
    const ownTags: string[] = [];
    let at = T0 + 1000 + Math.floor(rnd() * 500);
    const nextAt = () => (at += 1 + Math.floor(rnd() * 400));
    for (let k = 0; k < 45; k++) {
      const targets = [...editable, ...own];
      const r = rnd();
      const itemId = pick(targets);
      const base = { opId: uuidv7(), at: nextAt() };
      if (r < 0.12) {
        const id = uuidv7();
        own.push(id);
        const tags = rnd() < 0.5 ? [pick(SEED_TAGS)] : [];
        ops.push({ ...base, type: "item.add", itemId: id, url: pick(SHARED_URLS), tags });
      } else if (r < 0.25) {
        ops.push({ ...base, type: "item.setStatus", itemId, status: rnd() < 0.5 ? "archived" : "unread" });
      } else if (r < 0.35) {
        ops.push({ ...base, type: "item.setFavorite", itemId, value: rnd() < 0.5 });
      } else if (r < 0.45) {
        ops.push({ ...base, type: "item.setProgress", itemId, progress: Math.round(rnd() * 100) / 100, anchor: Math.floor(rnd() * 50) });
      } else if (r < 0.52) {
        ops.push({ ...base, type: "item.setTitle", itemId, title: rnd() < 0.2 ? "" : `${dev} title ${k}` });
      } else if (r < 0.8) {
        ops.push({ ...base, type: "item.tag", itemId, tag: pick(SEED_TAGS), present: rnd() < 0.6 });
      } else if (r < 0.92) {
        // own fresh tag (device-scoped name) — removal only after this device created it
        if (ownTags.length > 0 && rnd() < 0.4) {
          ops.push({ ...base, type: "item.tag", itemId, tag: pick(ownTags), present: false });
        } else {
          const name = `${dev}-t${Math.floor(rnd() * 3)}`;
          ownTags.push(name);
          ops.push({ ...base, type: "item.tag", itemId, tag: name, present: true });
        }
      } else {
        ops.push({ ...base, type: "item.delete", itemId: pick(deletable) });
      }
    }
    return { id: dev, ops };
  });
  // Tag-level ops happen "later" (after every item op), but devC pushes them in arbitrary position
  // relative to devA/devB → their item.tag ops become stale offline ops (api.md §8.4).
  const late = T0 + 1_000_000;
  devices[2]!.ops.push(
    { opId: uuidv7(), type: "tag.rename", from: "alpha", to: "Alpha Renamed", at: late },
    { opId: uuidv7(), type: "tag.rename", from: "beta", to: "GAMMA", at: late + 1 },
    { opId: uuidv7(), type: "tag.delete", tag: "delta", at: late + 2 },
  );
  return { seed, devices };
}

/** Random interleaving that preserves each device's order; returns push batches. */
function interleave(s: Scenario, rnd: () => number): { dev: string; ops: OpInput[] }[] {
  const idx = s.devices.map(() => 0);
  const batches: { dev: string; ops: OpInput[] }[] = [];
  for (;;) {
    const open = s.devices.map((d, i) => (idx[i]! < d.ops.length ? i : -1)).filter((i) => i >= 0);
    if (open.length === 0) break;
    const i = open[Math.floor(rnd() * open.length)]!;
    const n = 1 + Math.floor(rnd() * 6);
    const d = s.devices[i]!;
    batches.push({ dev: d.id, ops: d.ops.slice(idx[i]!, idx[i]! + n) });
    idx[i]! += n;
  }
  return batches;
}

async function snapshot(lib: ReturnType<typeof freshLibrary>["lib"]) {
  const r = await lib.pull(0, 1000);
  if (!r.ok) throw new Error("410");
  expect(r.data.hasMore).toBe(false);
  const items = r.data.items
    .map((i) => ({
      url: i.canonicalUrl,
      status: i.status,
      isFavorite: i.isFavorite,
      progress: i.progress,
      progressAnchor: i.progressAnchor,
      lastReadAt: i.lastReadAt,
      title: i.title,
      savedAt: i.savedAt,
      archivedAt: i.archivedAt,
      tags: i.tags,
    }))
    .sort((a, b) => (a.url < b.url ? -1 : 1));
  const tags = (await lib.listTags()).map((t) => [t.name, t.count]);
  return { items, deleted: [...r.data.deleted.items].sort(), tags, liveTags: r.data.tags.map((t) => t.name).sort() };
}

describe("sync convergence fuzz", () => {
  for (const seed of [1, 2, 3]) {
    it(`3 devices, random interleavings converge (seed ${seed})`, async () => {
      const rnd = mulberry32(seed);
      const scenario = makeScenario(rnd);
      const snaps: unknown[] = [];
      for (let order = 0; order < 4; order++) {
        const { lib } = freshLibrary(`fuzz${seed}`);
        await lib.applyOps("seed", scenario.seed);
        const batches =
          order === 0
            ? scenario.devices.map((d) => ({ dev: d.id, ops: d.ops })) // sequential A, B, C
            : interleave(scenario, rnd);
        for (const b of batches) await lib.applyOps(b.dev, b.ops);
        const snap = await snapshot(lib);
        // Idempotency: replaying every push changes nothing (cursor included).
        const cursor = (await lib.applyOps("seed", [])).response.cursor;
        for (const b of batches) await lib.applyOps(b.dev, b.ops);
        expect((await lib.applyOps("seed", [])).response.cursor).toBe(cursor);
        expect(await snapshot(lib)).toEqual(snap);
        snaps.push(snap);
      }
      const first = snaps[0] as Awaited<ReturnType<typeof snapshot>>;
      // sanity: the scenario exercised the interesting paths
      expect(first.tags.map((t) => t[0])).toContain("Alpha Renamed");
      expect(first.tags.map((t) => t[0])).not.toContain("beta");
      expect(first.tags.map((t) => t[0])).not.toContain("delta");
      for (const s of snaps.slice(1)) expect(s).toEqual(first);
    }, 20_000); // the first case pays the isolate cold start (~2.5 s alone, >5 s under full-suite load)
  }
});
