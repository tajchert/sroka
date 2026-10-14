# Sroka

Read-later app (a Pocket successor) on Cloudflare Workers: web app, Chrome extension, sync API for future mobile apps.

- Design: `docs/sroka-system-design.md` · Binding decisions: `docs/decisions.md` · HTTP/sync contract: `docs/api.md`
- Monorepo (npm workspaces): `packages/shared`, `packages/extractor`, `workers/api`, `workers/parser`, `apps/web`, `apps/extension`

```sh
nvm use            # Node 26
npm install
npm run typecheck
npm test
npm run dev -w @sroka/api   # wrangler dev on :8787
npm run dev -w @sroka/web   # vite on :5173
```
