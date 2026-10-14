# Brief: Cloudflare Email Service (Email Sending) from a Worker

Sources: the local skill `/Users/mtajchert/.claude/skills/cloudflare-email-service/SKILL.md` and its `references/*.md`, the live docs at developers.cloudflare.com/email-service (limits page updated 2026-09-25, pricing page 2026-06-09), and the local wrangler CLI help. I ran no throwaway project and changed nothing on the account.

## Versions (npm view, 2026-10-14)
- `wrangler` 4.151.0, which is what `npx wrangler` resolved to.
- `@cloudflare/workers-types` 5.20261014.1.
- `better-auth` 1.7.8.
- No extra package is needed to send. The binding is built into the runtime. `mimetext` is only needed for the legacy raw-MIME `EmailMessage` path.

## Two APIs, same binding
Use the **new Email Sending API**, which is `send_email` with a structured object. The legacy `EmailMessage` path (raw MIME via `cloudflare:email` and `mimetext`) is still supported, but the legacy binding required verified destination addresses (Email Routing). The new API plus an onboarded domain removes that restriction.

```jsonc
// wrangler.jsonc
{
  "compatibility_date": "2026-10-01",
  "send_email": [
    // No destination_address / allowed_destination_addresses -> unrestricted recipients
    { "name": "EMAIL" }
    // dev only: { "name": "EMAIL", "remote": true }
  ]
}
```

Do not set `destination_address` or `allowed_destination_addresses`. They restrict the binding to specific recipients. The Agents SDK example in the skill uses `destination_address` only for replies.

```ts
// Env typing: run `npx wrangler types`; it generates SendEmail / EmailAddress. Don't hand-write.
const res = await env.EMAIL.send({
  to: "user@example.com",                       // string | string[], max 50 total across to/cc/bcc
  from: { email: "noreply@sroka.app", name: "Sroka" },  // or a plain string
  subject: "Your Sroka sign-in code",
  text: `Your code is ${otp}. It expires in 10 minutes.`,
  html: `<p>Your code is <b>${otp}</b>. It expires in 10 minutes.</p>`,
  // optional: cc, bcc, replyTo, headers (whitelisted only), attachments
});
// res.messageId
```

Better Auth `emailOTP` wiring (the `sendVerificationOTP` signature is from my memory of the Better Auth docs, so confirm against 1.7.8):
```ts
emailOTP({
  async sendVerificationOTP({ email, otp, type }) {
    // On Workers, don't await-block the response if you can avoid it:
    ctx.waitUntil(env.EMAIL.send({ ... }));   // ctx via Hono c.executionCtx
  },
})
```
Better Auth recommends not awaiting the send, to avoid timing side channels. Use `waitUntil`, and log failures.

## Message format
- Structured `{to, from, subject, html, text}` is the preferred format.
- Always send both `html` and `text`.
- `from` is an object with `email` in the Workers binding, but `address` in the REST API. `replyTo` is camelCase in the binding and `reply_to` in REST.
- Attachments in the binding take raw strings or an ArrayBuffer, not base64. REST takes base64.
- Binding responses return `{messageId}`. REST returns `{delivered, permanent_bounces, queued}`.
- Raw MIME: `wrangler email sending send-raw` and the legacy `new EmailMessage(from, to, rawMime)` still exist. They are not needed for OTP.

## Sending to arbitrary recipients
- Before a sending domain is onboarded, you can send **only to verified destination addresses** (Email Routing addresses). Those sends are free.
- **After onboarding the domain, you can send to any recipient immediately** (limits page).
- Requires the **Workers Paid plan**. Email Sending is not available on Workers Free. Paid includes 3,000 outbound emails per month, then $0.35 per 1,000. Confirm the account is on Workers Paid before relying on this.
- New accounts start with a conservative daily quota that scales with reputation. Check it with `GET /accounts/{id}/email/sending/limits`, and request an increase through the form linked on the limits page.
- Message limits: 50 recipients per email, 5 MiB total (25 MiB only for verified destinations), 16 KB of headers, subject up to 998 characters.
- Transactional email only. Do not use it for marketing or bulk sends.

## Onboarding sroka.app (exact commands, not run)
Requires `wrangler login` as mtajchert@gmail.com, or a `CLOUDFLARE_API_TOKEN` with Email Sending and DNS edit permission. The zone is already on this account.

```bash
npx wrangler email sending list                      # see what's onboarded (all subdomains in the account)
npx wrangler email sending enable sroka.app --zone-id 7e814786800e88ac74b5acc9033370d4   # --zone-id is optional, skips the zone lookup
npx wrangler email sending dns get sroka.app         # shows SPF/DKIM records that were / must be added
npx wrangler email sending settings sroka.app        # verify status
# smoke test (sends a real mail; use an address you control):
npx wrangler email sending send --from noreply@sroka.app --to mtajchert@gmail.com --subject "test" --text "hi"
```

- Dashboard equivalent: Compute & AI > Email Service > Email Sending > Onboard Domain > choose domain > "Add records and onboard". It auto-adds the SPF TXT and DKIM records, and propagation takes about 5-15 minutes.
- Because the zone is on Cloudflare DNS, the records are added automatically. If they are not, `dns get` prints them for manual creation.
- Subdomain option: `enable` also accepts a subdomain such as `mail.sroka.app`. This isolates sending reputation from the root domain. Plain `noreply@sroka.app` is fine for now.
- Add a DMARC record manually, since the docs only suggest it. I did not check whether onboarding creates one. Suggested record: `_dmarc.sroka.app TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@sroka.app"`.
- Optionally enable Email Routing on sroka.app for inbound `dmarc@` and `support@` addresses. Sending does not need it.
- Any local part works once the domain is onboarded: `noreply@sroka.app`, `anything@sroka.app`.

## Wrangler CLI findings (local, 4.151.0)
`wrangler email` has two groups, both marked [open beta]:
- `wrangler email routing`: enable, disable, dns get, rules, addresses.
- `wrangler email sending`: `list [domain]`, `settings <domain>`, `enable <domain>` (option `--zone-id`), `disable <domain>`, `send` (builder flags `--from --to --subject --text/--html`), `send-raw`, `dns get <domain>`.

## Local development
- Without `"remote": true`, `wrangler dev` does not send real mail. I did not verify exactly what the local mock does, which may be logging or a local file. For OTP in dev, log the OTP to the console, or use `remote: true` with addresses you control.
- `ArrayBuffer` attachments do not work with `remote: true`. This is not relevant for OTP.
- Remove `"remote": true` before deploying.

## REST fallback (for scripts, or if the binding misbehaves)
```bash
curl "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/email/sending/send" \
 -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
 -d '{"to":"u@example.com","from":{"address":"noreply@sroka.app","name":"Sroka"},"subject":"x","text":"x"}'
```
A 429 means rate limited, so retry with backoff. A 1000 error with "Sender domain not verified" means onboarding is incomplete.

## Gotchas
1. The `from` domain must be onboarded. Otherwise the send fails with "Sender domain not verified".
2. The product is in open beta, so API shapes may shift. Pin wrangler, and re-check `workers-types` after upgrades.
3. Do not use fake or non-existent recipient addresses in tests. Bounces hurt reputation, and hard bounces count toward the quota.
4. Suppression lists exist (account level and per domain). A suppressed address is rejected at the API boundary, so handle send errors in the OTP flow.
5. Custom `headers` are whitelisted only (see the headers reference). Add `List-Unsubscribe` only if needed. It is not needed for OTP.
6. In the Workers binding, `send()` throws on failure. Wrap it in try/catch inside `waitUntil`.
7. Keep OTP email copy short, with a plain-text part, to help spam scoring.
8. Unverified: whether the free-tier Worker `wrangler dev` mock requires login. Also unverified: the exact default daily quota for this account, and whether DKIM selectors are added automatically in all cases. Run `dns get` after enabling to confirm.
