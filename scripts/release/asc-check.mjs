#!/usr/bin/env node
// Check an App Store Connect API key: signs an ES256 JWT and looks up the app by bundle id.
//   node scripts/release/asc-check.mjs <AuthKey_XXXX.p8> <keyId> <issuerId> [bundleId]
// Never prints the key or the token.
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const [keyPath, keyId, issuer, bundleId = 'app.sroka'] = process.argv.slice(2);
if (!keyPath || !keyId || !issuer) {
  console.error('usage: asc-check.mjs <AuthKey.p8> <keyId> <issuerId> [bundleId]');
  process.exit(2);
}
const b64url = (v) => Buffer.from(v).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
const claims = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' }));
const sig = createSign('SHA256')
  .update(`${head}.${claims}`)
  .sign({ key: readFileSync(keyPath, 'utf8'), dsaEncoding: 'ieee-p1363' }, 'base64url');

const url = `https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=name,bundleId`;
const res = await fetch(url, { headers: { authorization: `Bearer ${head}.${claims}.${sig}` } });
const body = await res.json().catch(() => ({}));
if (!res.ok) {
  console.error(`asc-check: ${res.status} ${body.errors?.[0]?.detail ?? body.errors?.[0]?.title ?? ''}`);
  process.exit(1);
}
const app = body.data?.[0];
if (!app) {
  console.error(`asc-check: key works, but no app with bundle id ${bundleId} is visible to it`);
  process.exit(1);
}
console.log(`ok: App Store Connect key works; app ${app.attributes.name} (${app.attributes.bundleId}, id ${app.id})`);
