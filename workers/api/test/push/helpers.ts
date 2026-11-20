import type { Fetch } from "../../src/push/index.ts";

const b64 = (buf: ArrayBuffer) => {
  let s = "";
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b);
  return btoa(s);
};
const pem = (der: ArrayBuffer) => `-----BEGIN PRIVATE KEY-----\n${b64(der).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;

export async function rsaKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const k = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  return { pem: pem((await crypto.subtle.exportKey("pkcs8", k.privateKey)) as ArrayBuffer), publicKey: k.publicKey };
}

export async function ecKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const k = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  return { pem: pem((await crypto.subtle.exportKey("pkcs8", k.privateKey)) as ArrayBuffer), publicKey: k.publicKey };
}

const fromB64url = (s: string) => {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
};

/** Decodes a JWT and verifies its signature with `publicKey`. */
export async function verifyJwt(jwt: string, publicKey: CryptoKey): Promise<{ header: any; claims: any; valid: boolean }> {
  const [h, c, sig] = jwt.split(".") as [string, string, string];
  const params = publicKey.algorithm.name === "ECDSA" ? { name: "ECDSA", hash: "SHA-256" } : { name: "RSASSA-PKCS1-v1_5" };
  const valid = await crypto.subtle.verify(params, publicKey, fromB64url(sig), new TextEncoder().encode(`${h}.${c}`));
  const dec = (s: string) => JSON.parse(new TextDecoder().decode(fromB64url(s)));
  return { header: dec(h), claims: dec(c), valid };
}

export type Call = { url: string; method: string; headers: Record<string, string>; body: string };

/** Fake fetch: records calls; `respond` decides the response per call. */
export function fakeFetch(respond: (call: Call) => Response | Promise<Response>): { fetch: Fetch; calls: Call[] } {
  const calls: Call[] = [];
  const f: Fetch = async (url, init) => {
    const call: Call = {
      url,
      method: init.method ?? "GET",
      headers: Object.fromEntries(new Headers(init.headers).entries()),
      body: typeof init.body === "string" ? init.body : "",
    };
    calls.push(call);
    return respond(call);
  };
  return { fetch: f, calls };
}

export const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** Responds to Google's OAuth token endpoint, else defers to `rest`. */
export function withOauth(rest: (c: Call) => Response | Promise<Response>, token = "access-1") {
  return (c: Call) => (c.url === "https://oauth2.googleapis.com/token" ? json(200, { access_token: token, expires_in: 3600, token_type: "Bearer" }) : rest(c));
}

export async function serviceAccount() {
  const k = await rsaKey();
  const sa = { type: "service_account", project_id: "sroka-95489", client_email: `push-${crypto.randomUUID()}@sroka-95489.iam.gserviceaccount.com`, private_key: k.pem };
  return { json: JSON.stringify(sa), sa, publicKey: k.publicKey };
}
