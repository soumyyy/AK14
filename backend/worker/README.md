# AK14 Worker

The Worker proxies AK14 Responses requests, serves the versioned StylePack config, and accepts privacy-limited product analytics. The OpenAI key stays in a Worker secret. Requests can authenticate with a development invite or a 30-day Sign in with Apple session.

## Local development

```bash
cd backend/worker
npm install
cp .dev.vars.example .dev.vars
node scripts/issue-invite.js
```

The helper prints a plaintext invite once and its SHA-256 hash. Put the plaintext token in the app during development, and put the hash in `.dev.vars` as `INVITE_TOKEN_HASHES=<hash>`. Invites and Apple sessions coexist: either bearer token can call responses and analytics. Set `APPLE_BUNDLE_ID=com.ak14.app`, `ADMIN_TOKEN`, `DAILY_REQUEST_CAP`, `DAILY_SPEND_CAP_USD`, and `MONTHLY_RUN_CAP` (default 60) in `.dev.vars`. `OPENAI_API_KEY` and `ADMIN_TOKEN` are secrets; keep `.dev.vars` private. `npm run check` runs the Worker checks; `npm run dev` starts the Worker at `http://127.0.0.1:8787`.

## Sign in with Apple

In the Apple Developer account, enable the Sign in with Apple capability for the `com.ak14.app` App ID and enable the matching capability in the iOS app target. The Worker verifies Apple identity JWTs against Apple's rotating JWKS, cached in `AK14_USAGE` for 24 hours. Configure `APPLE_BUNDLE_ID` to the exact app bundle ID. `POST /v1/auth/apple` accepts `{ "identityToken": "..." }` and returns a 30-day AK14 session. The Worker stores only a SHA-256 hash of the Apple subject as the user ID; it never stores Apple's raw subject or email. The opaque session token is returned once and only its SHA-256 hash is stored.

## Deploy

Run these from `backend/worker`:

1. Authenticate Wrangler: `npx wrangler login`.
2. Create a KV namespace if needed: `npx wrangler kv namespace create AK14_USAGE`. The production namespace is already created and its binding is recorded in `wrangler.jsonc`.
3. Set the provider secret: `npx wrangler secret put OPENAI_API_KEY`.
4. Generate an invite with `node scripts/issue-invite.js`. Give the printed plaintext token to its intended user once. Add only its SHA-256 hash to the comma-separated `INVITE_TOKEN_HASHES` value in `wrangler.jsonc` `vars`, then deploy. Configure `DAILY_REQUEST_CAP` and `DAILY_SPEND_CAP_USD` in the same vars section before deploying.
5. Set secrets with Wrangler: `npx wrangler secret put ADMIN_TOKEN` and `npx wrangler secret put OPENAI_API_KEY`. Configure `APPLE_BUNDLE_ID`, `DAILY_REQUEST_CAP`, `DAILY_SPEND_CAP_USD`, and `MONTHLY_RUN_CAP` in Worker vars.
6. Deploy: `npm run deploy`.
7. Copy the deployed Worker URL into the iOS app's Worker URL setting. During development, enter an invite plaintext token; production clients can exchange an Apple identity token for a session.

To add an invite, generate another token and add its hash to `INVITE_TOKEN_HASHES`; to revoke one, remove its hash. Daily request and spend caps apply per invite hash or session user ID, per UTC day. The monthly run cap applies to requests using the `planner` schema, per user and UTC month. `POST /v1/events` accepts up to 100 allow-listed events per batch, with flat string/number properties (up to 12 keys); event names and daily aggregates are stored in KV. `GET /v1/admin/metrics?days=7` requires `Authorization: Bearer <ADMIN_TOKEN>`. Structured logs contain user ID hashes, aggregate batch sizes, and model usage, never request content, photos, Apple subjects, or email. Cost uses gpt-6-luna rates of $0.10 per million uncached input tokens, $0.01 per million cached input tokens, and $0.50 per million output tokens.

`GET /health` and `GET /v1/config` do not need an invite. Responses requests are restricted to AK14's bounded schema, image, output and model shape, and set `store: false`.
