# AK14 Worker

The Worker proxies AK14 Responses requests and serves the versioned StylePack config. The OpenAI key stays in a Worker secret. `POST /v1/responses` requires a random invite token whose SHA-256 hash is configured in `INVITE_TOKEN_HASHES`.

## Local development

```bash
cd backend/worker
npm install
cp .dev.vars.example .dev.vars
node scripts/issue-invite.js
```

The helper prints a plaintext invite once and its SHA-256 hash. Put the plaintext token in the app during development, and put the hash in `.dev.vars` as `INVITE_TOKEN_HASHES=<hash>`. Configure `DAILY_REQUEST_CAP` and `DAILY_SPEND_CAP_USD` there as well. Keep `.dev.vars` private. `npm run check` runs the Worker end-to-end checks; `npm run dev` starts the local Worker at `http://127.0.0.1:8787`.

## Deploy

Run these from `backend/worker`:

1. Authenticate Wrangler: `npx wrangler login`.
2. Create a KV namespace if needed: `npx wrangler kv namespace create AK14_USAGE`. The production namespace is already created and its binding is recorded in `wrangler.jsonc`.
3. Set the provider secret: `npx wrangler secret put OPENAI_API_KEY`.
4. Generate an invite with `node scripts/issue-invite.js`. Give the printed plaintext token to its intended user once. Add only its SHA-256 hash to the comma-separated `INVITE_TOKEN_HASHES` value in `wrangler.jsonc` `vars`, then deploy. Configure `DAILY_REQUEST_CAP` and `DAILY_SPEND_CAP_USD` in the same vars section before deploying.
5. Deploy: `npm run deploy`.
6. Copy the deployed Worker URL into the iOS app's Worker URL setting. Enter the invite plaintext token in the app's invite setting.

To add an invite, generate another token and add its hash to `INVITE_TOKEN_HASHES`, separated by commas, then deploy the updated configuration. To revoke one, remove its hash and deploy. Existing KV counters are keyed by the token hash and UTC date and expire after two days. Each successful upstream response logs one structured JSON line with the token hash, model, input/cached/output token counts, and estimated cost. Request content and images are never logged. Cost uses gpt-6-luna rates of $0.10 per million uncached input tokens, $0.01 per million cached input tokens, and $0.50 per million output tokens.

`GET /health` and `GET /v1/config` do not need an invite. Responses requests are restricted to AK14's bounded schema, image, output and model shape, and set `store: false`.
