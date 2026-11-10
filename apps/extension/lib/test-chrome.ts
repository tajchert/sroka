import { vi } from "vitest";

/** Minimal in-memory chrome mock (storage.local/session, alarms, action, scripting). */
export function installChrome() {
  const mkArea = () => {
    const data: Record<string, unknown> = {};
    return {
      data,
      get: vi.fn(async (keys?: string | string[]) => {
        const ks = keys == null ? Object.keys(data) : Array.isArray(keys) ? keys : [keys];
        return Object.fromEntries(ks.filter((k) => k in data).map((k) => [k, structuredClone(data[k])]));
      }),
      set: vi.fn(async (o: Record<string, unknown>) => void Object.assign(data, structuredClone(o))),
      remove: vi.fn(async (keys: string | string[]) => void [keys].flat().forEach((k) => delete data[k])),
    };
  };
  const local = mkArea();
  const session = mkArea();
  const chromeMock = {
    storage: { local, session },
    runtime: { getManifest: vi.fn(() => ({ version: "9.9.9" })), sendMessage: vi.fn(async () => undefined) },
    alarms: { create: vi.fn(async () => {}), clear: vi.fn(async () => true) },
    action: {
      setBadgeText: vi.fn(async () => {}),
      setBadgeBackgroundColor: vi.fn(async () => {}),
      setBadgeTextColor: vi.fn(async () => {}),
    },
    scripting: { executeScript: vi.fn(async () => [{ result: "<html></html>" }]) },
  };
  (globalThis as unknown as { chrome: unknown }).chrome = chromeMock;
  return chromeMock;
}

export function jsonRes(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

/** JSON body of a mocked fetch call; gunzips `Content-Encoding: gzip` bodies. */
export async function requestJson(init: RequestInit | undefined): Promise<Record<string, unknown>> {
  const b = init?.body;
  if (b instanceof ArrayBuffer) {
    const stream = new Blob([b]).stream().pipeThrough(new DecompressionStream("gzip"));
    return JSON.parse(await new Response(stream).text());
  }
  return JSON.parse(String(b));
}

type PullItem = { id: string; url: string; canonicalUrl?: string };

/** One `GET /v1/sync/pull` page. */
export function pullPage(items: PullItem[], opts: { cursor?: number; hasMore?: boolean; deleted?: string[] } = {}) {
  return jsonRes(200, {
    cursor: opts.cursor ?? 1,
    hasMore: opts.hasMore ?? false,
    items: items.map((i) => ({ canonicalUrl: i.url, ...i })),
    tags: [],
    deleted: { items: opts.deleted ?? [], tags: [] },
  });
}

/** Loads the local saved set (lib/saved-set.ts) from one mocked pull page. */
export async function loadSavedSet(items: PullItem[], cursor = 1) {
  const { refreshSavedSet } = await import("./saved-set.ts");
  const f = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(pullPage(items, { cursor }));
  const ok = await refreshSavedSet();
  f.mockRestore();
  if (!ok) throw new Error("saved set did not load");
}
