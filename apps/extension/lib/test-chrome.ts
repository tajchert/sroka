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
