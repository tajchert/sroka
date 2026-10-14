# Cloudflare resources (production, account 7e814786800e88ac74b5acc9033370d4)

| Resource | Name | ID |
|---|---|---|
| Zone | sroka.app | d5fc553a2cf4bd2fc4bdb6e6bb90e466 |
| D1 | sroka | 4909f01f-3368-4169-9af8-e95144376aed |
| R2 bucket | sroka-content | — |
| KV namespace | sroka-config | 3fffa4e503274f16a3698f72f9a089c9 |
| Queue | sroka-parse | 1a2c1b831d7742b6ac54371185418b68 |
| Queue (DLQ) | sroka-parse-dlq | 22a50a84f5344daaa9c12a907720a57a |
| Turnstile widget | sroka-web-login (managed; sroka.app, localhost, 127.0.0.1) | sitekey 0x4AAAAAAFXEWydv4XHizEV8; secret in sroka-api secret TURNSTILE_SECRET_KEY |
| Email Sending | sroka.app (enabled 2026-10-14; SPF/DKIM on cf-bounce.sroka.app, DMARC p=reject) | — |

Secrets to set on deploy: `BETTER_AUTH_SECRET`, `CONTENT_URL_SIGNING_KEY` (sroka-api, and signing key on sroka-parser if it signs).
