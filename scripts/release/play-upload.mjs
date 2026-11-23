#!/usr/bin/env node
// Upload an Android App Bundle to Google Play with the Android Publisher API v3 (edits flow).
// No dependencies: Node's crypto signs the service-account JWT, fetch talks to the API.
//
//   node scripts/release/play-upload.mjs --key <service-account.json> --package app.sroka --check
//   node scripts/release/play-upload.mjs --key <sa.json> --package app.sroka --aab <file.aab>
//        [--mapping mapping.txt] [--track internal] [--status completed|draft] [--notes notes.txt]
//
// --check only proves the key works and has access to the app (opens and deletes an edit).
// Never prints the key or the access token.
import { createSign } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { parseArgs } from 'node:util';

const { values: a } = parseArgs({
  options: {
    key: { type: 'string' },
    package: { type: 'string' },
    aab: { type: 'string' },
    mapping: { type: 'string' },
    track: { type: 'string', default: 'internal' },
    status: { type: 'string', default: 'completed' },
    notes: { type: 'string' },
    check: { type: 'boolean', default: false },
  },
});
const fail = (msg) => {
  console.error(`play-upload: ${msg}`);
  process.exit(1);
};
if (!a.key || !a.package) fail('--key and --package are required');
if (!a.check && !a.aab) fail('--aab is required (or --check)');
if (!['completed', 'draft'].includes(a.status)) fail('--status must be completed or draft');
if (a.track === 'production') fail('refusing the production track; promote in Play Console');

const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const UPLOAD = 'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications';
const pkg = encodeURIComponent(a.package);

const b64url = (v) => Buffer.from(v).toString('base64url');
async function accessToken() {
  const sa = JSON.parse(readFileSync(a.key, 'utf8'));
  if (sa.type !== 'service_account') fail('key file is not a service account JSON key');
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: 'https://www.googleapis.com/auth/androidpublisher',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const sig = createSign('RSA-SHA256').update(`${head}.${claims}`).sign(sa.private_key, 'base64url');
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${head}.${claims}.${sig}`,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) fail(`token request failed (${res.status}): ${body.error ?? ''} ${body.error_description ?? ''}`);
  console.log(`authenticated as ${sa.client_email}`);
  return body.access_token;
}

const token = await accessToken();
async function call(method, url, { json, file, type } = {}) {
  const headers = { authorization: `Bearer ${token}` };
  let body;
  if (json) {
    headers['content-type'] = 'application/json';
    body = JSON.stringify(json);
  } else if (file) {
    headers['content-type'] = type;
    body = readFileSync(file);
  }
  const res = await fetch(url, { method, headers, body });
  const text = await res.text();
  if (!res.ok) {
    let msg = text;
    try {
      msg = JSON.parse(text).error?.message ?? text;
    } catch {}
    throw new Error(`${method} ${url.replace(/\?.*/, '')} -> ${res.status}: ${msg}`);
  }
  return text ? JSON.parse(text) : {};
}

const edit = await call('POST', `${API}/${pkg}/edits`, { json: {} });
const E = `${API}/${pkg}/edits/${edit.id}`;
const U = `${UPLOAD}/${pkg}/edits/${edit.id}`;
let committed = false;
try {
  if (a.check) {
    const tracks = await call('GET', `${E}/tracks`);
    console.log(`ok: access to ${a.package}; tracks: ${(tracks.tracks ?? []).map((t) => t.track).join(', ')}`);
  } else {
    const mb = (statSync(a.aab).size / 1e6).toFixed(1);
    console.log(`uploading ${a.aab} (${mb} MB)…`);
    const bundle = await call('POST', `${U}/bundles?uploadType=media`, {
      file: a.aab,
      type: 'application/octet-stream',
    });
    console.log(`uploaded versionCode ${bundle.versionCode}`);
    if (a.mapping) {
      await call('POST', `${U}/apks/${bundle.versionCode}/deobfuscationFiles/proguard?uploadType=media`, {
        file: a.mapping,
        type: 'application/octet-stream',
      });
      console.log('uploaded R8 mapping');
    }
    const release = { versionCodes: [String(bundle.versionCode)], status: a.status };
    if (a.notes) release.releaseNotes = [{ language: 'en-US', text: readFileSync(a.notes, 'utf8').trim() }];
    await call('PUT', `${E}/tracks/${encodeURIComponent(a.track)}`, {
      json: { track: a.track, releases: [release] },
    });
    await call('POST', `${E}:commit`);
    committed = true;
    console.log(`ok: versionCode ${bundle.versionCode} on track '${a.track}' (${a.status})`);
  }
} catch (err) {
  console.error(`play-upload: ${err.message}`);
  if (/draft app/i.test(err.message)) console.error('hint: the app is unpublished; rerun with --status draft');
  process.exitCode = 1;
} finally {
  if (!committed) await call('DELETE', E).catch(() => {});
}
