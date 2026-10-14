# Better Auth on Workers + D1 (Drizzle) with emailOTP and bearer: research brief

All of the code below was built and run in `/private/tmp/claude-501/sroka-research/better-auth/`. It passes `tsc`, and I ran it under `wrangler dev` against a local D1. The full email-OTP sign-in worked: the OTP was sent, sign-in returned `set-auth-token`, and a bearer-authenticated `/api/me` returned the user. I could not read `sroka-system-design.md` (the file wasn't at the repo path), so §10 specifics are unchecked.

## Versions (npm view, 2026-10-14)
| Package | Version |
|---|---|
| `better-auth` | 1.7.8 (includes `@better-auth/drizzle-adapter` 1.7.8) |
| `@better-auth/cli` | 1.4.21 (works with 1.7.8 for schema generation) |
| `drizzle-orm` | 0.45.4 |
| `drizzle-kit` | 0.31.11 |
| `hono` | 4.13.13 |
| `wrangler` | 4.151.0 |
| `@cloudflare/workers-types` | 5.20261014.1 |
| `typescript` | 5.9.3 (used in the test; 7.0.2 is latest and not tested) |

Install: `npm i better-auth drizzle-orm hono && npm i -D drizzle-kit @better-auth/cli wrangler @cloudflare/workers-types`

## wrangler.jsonc
```jsonc
{
  "name": "sroka-api",
  "main": "src/index.ts",
  "compatibility_date": "2026-10-01",
  "compatibility_flags": ["nodejs_compat"],   // verified working; see gotchas
  "d1_databases": [{ "binding": "DB", "database_name": "sroka", "database_id": "<id>", "migrations_dir": "migrations" }],
  "vars": { "BETTER_AUTH_URL": "https://api.sroka.app" }
}
```
Set the secret with `wrangler secret put BETTER_AUTH_SECRET`. For local dev, put it in `.dev.vars` as 32+ random characters. A low-entropy secret only logs a warning.

## Per-request construction
Bindings exist only inside `fetch`, so `createAuth(env, ctx)` builds the instance on every request. It is cheap, and the test ran fine this way. Don't cache it in a module global.

```ts
// src/auth.ts
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer, emailOTP } from "better-auth/plugins";
import { drizzle } from "drizzle-orm/d1";
import * as schema from "./auth-schema";

export interface Env { DB: D1Database; BETTER_AUTH_SECRET: string; BETTER_AUTH_URL: string }

export function createAuth(env: Env, ctx?: { waitUntil(p: Promise<unknown>): void }) {
  const db = drizzle(env.DB, { schema });
  return betterAuth({
    baseURL: env.BETTER_AUTH_URL,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db, { provider: "sqlite", schema }),
    trustedOrigins: ["https://sroka.app", "https://www.sroka.app", "chrome-extension://<EXT_ID>"],
    session: {
      expiresIn: 60 * 60 * 24 * 90,   // 90 days
      updateAge: 60 * 60 * 24,        // rolling: expiry is pushed out at most once per day when the session is used
      cookieCache: { enabled: true, maxAge: 300 },  // saves a D1 read per request
    },
    rateLimit: { enabled: true, window: 60, max: 100, storage: "database" },
    advanced: {
      crossSubDomainCookies: { enabled: true, domain: ".sroka.app" },
      defaultCookieAttributes: { sameSite: "lax", secure: true, httpOnly: true },
      ipAddress: { ipAddressHeaders: ["cf-connecting-ip"] },
    },
    plugins: [
      bearer(),
      emailOTP({
        otpLength: 6, expiresIn: 600, allowedAttempts: 3, storeOTP: "hashed",
        async sendVerificationOTP({ email, otp, type }) {
          const p = sendEmail(email, otp, type);      // e.g. Cloudflare Email Service
          ctx ? ctx.waitUntil(p) : await p;            // don't await: avoids a timing side channel
        },
      }),
    ],
  });
}
```

## Hono mount and CORS
```ts
const app = new Hono<{ Bindings: Env }>();
app.use("/api/*", cors({
  origin: (o) => (o === "https://sroka.app" || o.startsWith("chrome-extension://") ? o : null),
  credentials: true,
  allowHeaders: ["Content-Type", "Authorization"],
  allowMethods: ["GET","POST","PUT","PATCH","DELETE","OPTIONS"],
  exposeHeaders: ["set-auth-token"],
  maxAge: 600,
}));
app.on(["GET","POST"], "/api/auth/*", (c) => createAuth(c.env, c.executionCtx).handler(c.req.raw));
app.get("/api/me", async (c) => {
  const s = await createAuth(c.env, c.executionCtx).api.getSession({ headers: c.req.raw.headers });
  return s ? c.json(s.user) : c.json({ error: "unauthorized" }, 401);
});
```
- The bearer plugin already adds `set-auth-token` to `Access-Control-Expose-Headers`. Hono's `cors` middleware also lists it, which is harmless.
- Use a CORS allow-list (the function above), never `*` together with credentials.
- If `/api/auth/*` is served from the same worker as the other `/api/*` routes, `getSession({headers})` works for both cookie and bearer auth. The plugin's before-hook converts `Authorization: Bearer` into a session cookie.

## Schema generation
Better Auth needs a file that exports `auth`. The CLI can't call a factory with real bindings, so use a stub config:
```ts
// auth.cli.ts
import { createAuth } from "./src/auth";
export const auth = createAuth({ DB: {} as any, BETTER_AUTH_SECRET: "x".repeat(32), BETTER_AUTH_URL: "http://localhost:8787" });
```
```
npx @better-auth/cli generate --config auth.cli.ts --output src/auth-schema.ts -y
npx drizzle-kit generate          # drizzle.config.ts: dialect "sqlite", schema ./src/auth-schema.ts, out ./migrations
npx wrangler d1 migrations apply sroka --local    # --remote for production
```
- `src/auth-schema.ts` must exist before the first run, because `auth.ts` imports it. `touch` it first.
- The CLI printed "Drizzle schema mismatch / Missing tables" on the first run. That is expected because the file was empty, and it then wrote the schema.
- The generated tables are `user`, `session`, `account`, `verification` and `rate_limit`.
- Regenerate whenever you add plugins or change options.

## Cookies, domains, SameSite
- With `crossSubDomainCookies.domain=".sroka.app"`, the cookie is `Domain=.sroka.app; Secure; HttpOnly; SameSite=Lax; Max-Age=7776000`. I saw exactly this from the worker.
- `sroka.app` and `api.sroka.app` are same-site, so Lax cookies work on `fetch(..., {credentials:"include"})` from the SPA. You don't need `SameSite=None`.
- The client needs `createAuthClient({ baseURL: "https://api.sroka.app", fetchOptions: { credentials: "include" } })`.
- If the SPA and API ever share an origin (the SPA served as Worker static assets on the same host), cross-subdomain cookies and CORS aren't needed at all. That is simpler, and I recommend considering it.
- Better Auth also sets a `session_data` cookie (the cookie cache, 5 minutes).
- Origin/CSRF check: for requests carrying cookies, the `Origin` must be in `trustedOrigins`.

## Bearer token for the extension
- A successful `POST /api/auth/sign-in/email-otp` returns the response header `set-auth-token: <token>.<signature>`. Verified: the body is a user/token JSON and the header is present.
- The extension's flow is:
  1. `POST /api/auth/email-otp/send-verification-otp` with `{email, type:"sign-in"}`.
  2. `POST /api/auth/sign-in/email-otp` with `{email, otp}`.
  3. Read `res.headers.get("set-auth-token")` and store it in `chrome.storage.local`.
  4. Send `Authorization: Bearer <token>` on all later calls.
- With the better-auth client, `fetchOptions.onSuccess` can read the header, and `auth: { type: "Bearer", token: () => ... }` sets it on requests. I did not test the client library.
- The token is not URL-encoded; it contains `=`. Send it as is.
- I called `/api/me` with `Origin: chrome-extension://abc` (not in `trustedOrigins`) and only the bearer header, and it returned the user. No cookie means no origin check, so bearer requests work.
- `bearer({ requireSignature: true })` rejects unsigned raw tokens. The default accepts a raw session token and signs it internally.
- A bearer token still maps to a DB session, so sign-out and revocation work normally.
- MV3 service workers with `host_permissions: ["https://api.sroka.app/*"]` bypass CORS. The CORS allow-list for `chrome-extension://` is only a fallback. Also add the extension origin to `trustedOrigins` for safety.
- The extension ID changes between unpacked and store builds unless you pin `key` in the manifest.

## emailOTP options (types verified in 1.7.8)
| Option | Default | Notes |
|---|---|---|
| `otpLength` | 6 | |
| `expiresIn` | 300 | seconds |
| `allowedAttempts` | 3 | |
| `storeOTP` | `"plain"` | Set `"hashed"` (also `"encrypted"` or custom). |
| `resendStrategy` | `"rotate"` | `"reuse"` falls back to rotate when hashed. |
| `disableSignUp` | false | |
| `sendVerificationOnSignUp` | false | |
| `overrideDefaultEmailVerification` | false | |
| `generateOTP` | built-in | |
| `rateLimit` | `{window:60, max:3}` | Plugin-level limit on the OTP endpoints. |

- `sendVerificationOTP(data, ctx)` receives `type: "sign-in" | "email-verification" | "forget-password" | "change-email"`.
- Signing in with an OTP creates the user if they don't exist and sets `emailVerified: true`.
- A used OTP is deleted from `verification`.

## Rate limiting storage
- The default is in-memory, which is per-isolate and unreliable on Workers.
- `storage: "database"` uses the `rate_limit` table in D1. Verified: the table is generated and the sign-in flow works. It is simple and consistent.
- `storage: "secondary-storage"` needs a KV-backed `secondaryStorage`, and KV is eventually consistent. Gotcha: setting `secondaryStorage` makes sessions live only in KV and removes the `session` table from the generated schema. In my test, adding it dropped `session` from the schema. Use `session.storeSessionInDatabase: true` if you want both (not tested), or avoid it.
- `rateLimit.customStorage` (interface `BetterAuthRateLimitStorage`, an atomic record-and-check) lets you plug in a Durable Object or the Workers Rate Limiting binding. I confirmed the type exists but didn't implement it.
- The client IP comes from `advanced.ipAddress.ipAddressHeaders: ["cf-connecting-ip"]`.
- `rateLimit.enabled` defaults to true only in production, so set it explicitly. Add `customRules` for `/email-otp/*` or `/sign-in/*`.

## Gotchas
1. `nodejs_compat` was set in my config and the app ran. I did not test without it. Keep it on (the `D1Database` types come from `@cloudflare/workers-types`).
2. With `workers-types` 5.x, passing Hono's `c.executionCtx` into a parameter typed `ExecutionContext` failed `tsc` ("missing tracing, abort"). The structural type `{waitUntil(p): void}` fixes it.
3. The CLI needs an exported `auth`, so keep a separate `auth.cli.ts` as shown above.
4. D1 has no interactive transactions. Better Auth ran fine through Drizzle's D1 driver, but multi-step operations aren't atomic. I did not test this under load.
5. Local `.dev.vars` is read by `wrangler dev`, not by the CLI. The CLI stub uses a dummy secret.
6. `Secure` cookies work on `localhost` in browsers, but the cross-domain `.sroka.app` cookie will not be accepted on localhost. For local dev, use same-origin or the bearer flow.
7. Production steps I did not do (they need your Cloudflare account): D1 creation, `wrangler secret put`, the custom domain routes, and the email provider.
