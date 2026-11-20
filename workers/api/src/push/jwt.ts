/** Minimal JWT signing for the push senders (WebCrypto only): RS256 (Google service account), ES256 (APNs .p8). */

export type Fetch = (input: string, init: RequestInit) => Promise<Response>;

const enc = new TextEncoder();

export function base64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? enc.encode(bytes) : bytes;
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]!);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** PEM (PKCS#8 "PRIVATE KEY", any line breaks, literal `\n` tolerated) → DER bytes. */
export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export type JwtAlg = "RS256" | "ES256";

export function importSigningKey(pem: string, alg: JwtAlg): Promise<CryptoKey> {
  const params = alg === "RS256" ? { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" } : { name: "ECDSA", namedCurve: "P-256" };
  return crypto.subtle.importKey("pkcs8", pemToDer(pem), params, false, ["sign"]);
}

/** Signs `header.claims`. WebCrypto ECDSA already returns the raw r||s form JWS ES256 expects. */
export async function signJwt(key: CryptoKey, alg: JwtAlg, header: Record<string, unknown>, claims: Record<string, unknown>): Promise<string> {
  const input = `${base64url(JSON.stringify({ alg, typ: "JWT", ...header }))}.${base64url(JSON.stringify(claims))}`;
  const params = alg === "RS256" ? { name: "RSASSA-PKCS1-v1_5" } : { name: "ECDSA", hash: "SHA-256" };
  const sig = new Uint8Array(await crypto.subtle.sign(params, key, enc.encode(input)));
  return `${input}.${base64url(sig)}`;
}
