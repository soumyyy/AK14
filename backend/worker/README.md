# AK14 Worker (local Phase 1 backend)

This Worker proxies the exact Responses request shape used by AK14 and serves a versioned StylePack config. It has not been deployed. The iOS app uses `WorkerTransport`; the OpenAI key remains a Worker secret.

## Local setup

```bash
cd backend/worker
npm install
cp .dev.vars.example .dev.vars
# Fill in local secrets in .dev.vars; never commit that file.
npm run check
npm run dev
```

The local API is `http://127.0.0.1:8787`; `GET /health` and `GET /v1/config` do not need an invite. `POST /v1/responses` requires `Authorization: Bearer <invite>`. Issue a short-lived, pseudonymous invite locally with:

```bash
INVITE_SIGNING_KEY='<the same 32+ byte secret>' node scripts/issue-invite.js P01 7
```

Paste that invite into the development app. Never embed a shared invite or the signing key in the app bundle. The Worker only accepts `gpt-6-luna`, AK14's schema names, text/JPEG inputs, `store: false`, and bounded request/output sizes. The per-invite rate limit is five requests per minute through the Cloudflare binding. That limit is per Cloudflare location and is not a hard spending cap. Before distributing the app, add a global per-invite quota and an invite provisioning/revocation workflow.

The StylePack in `src/style-config.json` is currently a remote copy of the bundled `starter-editorial` pack. A test checks that the two match. A change to a StylePack must change its version and the config ETag, and old run snapshots must keep their pinned version.

## Deploy preparation

Set `OPENAI_API_KEY` and `INVITE_SIGNING_KEY` as Worker secrets using Wrangler, review the access/quotas above, then deploy from a Cloudflare account. Keep `.dev.vars` local. No account configuration or deployment is performed by this repository.

OpenAI Responses requests explicitly use `store: false`, which disables default response application-state storage. Standard abuse-monitoring retention is a separate account policy; review it and update user-facing consent before distribution.
