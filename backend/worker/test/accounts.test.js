import test from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { createHandler } from "../src/index.js";

class KV {
  values = new Map();
  async get(key) { return this.values.get(key) ?? null; }
  async put(key, value) { this.values.set(key, String(value)); }
}
const kv = () => new KV();
const b64 = value => Buffer.from(JSON.stringify(value)).toString("base64url");
function fixture() {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = publicKey.export({ format: "jwk" }); Object.assign(jwk, { kid: "test-key", alg: "RS256", use: "sig" });
  function jwt(claims = {}, key = privateKey) {
    const head = b64({ alg: "RS256", kid: "test-key" }), payload = b64({ iss: "https://appleid.apple.com", aud: "com.ak14.app", exp: Math.floor(Date.now() / 1000) + 3600, sub: "private-apple-sub", ...claims });
    const input = `${head}.${payload}`; return `${input}.${sign("RSA-SHA256", Buffer.from(input), key).toString("base64url")}`;
  }
  return { jwk, jwt, privateKey };
}
function req(path, method, body, token) {
  return new Request(`https://worker.test${path}`, { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
}
const invite = "development-invite", inviteHash = createHash("sha256").update(invite).digest("hex");
const validBody = schema => ({ model: "gpt-6-luna", store: false, max_output_tokens: 20, reasoning: { effort: "low" }, text: { format: { type: "json_schema", name: schema, strict: true, schema: { type: "object" } } }, input: [{ role: "system", content: "s" }, { role: "user", content: [{ type: "input_text", text: "hello" }] }] });

test("Apple JWT verifier accepts valid RS256 and rejects expired, wrong audience, and invalid signature", async () => {
  const f = fixture(), env = { AK14_USAGE: kv(), APPLE_BUNDLE_ID: "com.ak14.app", fetchAppleJWKS: async () => Response.json({ keys: [f.jwk] }) };
  const handler = createHandler();
  const valid = await handler(req("/v1/auth/apple", "POST", { identityToken: f.jwt() }), env);
  assert.equal(valid.status, 200);
  assert.equal((await handler(req("/v1/auth/apple", "POST", { identityToken: f.jwt({ exp: 1 }) }), env)).status, 401);
  assert.equal((await handler(req("/v1/auth/apple", "POST", { identityToken: f.jwt({ aud: "wrong" }) }), env)).status, 401);
  assert.equal((await handler(req("/v1/auth/apple", "POST", { identityToken: f.jwt({}, generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey) }), env)).status, 401);
});

test("Apple session is issued as a hashed 256-bit token and authenticates responses", async () => {
  const f = fixture(), usage = kv(), env = { AK14_USAGE: usage, APPLE_BUNDLE_ID: "com.ak14.app", OPENAI_API_KEY: "key", INVITE_TOKEN_HASHES: inviteHash, fetchAppleJWKS: async () => Response.json({ keys: [f.jwk] }) };
  const handler = createHandler(async () => Response.json({ usage: {} }));
  const response = await handler(req("/v1/auth/apple", "POST", { identityToken: f.jwt() }), env), data = await response.json();
  assert.equal(response.status, 200); assert.equal(Buffer.from(data.sessionToken, "hex").length, 32);
  const stored = [...usage.values.entries()].find(([key]) => key.startsWith("session:"));
  assert.ok(stored); assert.equal(stored[1].includes("private-apple-sub"), false);
  assert.equal((await handler(req("/v1/responses", "POST", validBody("triage"), data.sessionToken), env)).status, 200);
});

test("per-user daily quotas and planner monthly run cap return machine-readable limits", async () => {
  const usage = kv(), env = { AK14_USAGE: usage, OPENAI_API_KEY: "key", INVITE_TOKEN_HASHES: inviteHash, DAILY_REQUEST_CAP: "2", MONTHLY_RUN_CAP: "1" };
  const handler = createHandler(async () => Response.json({ usage: {} }));
  assert.equal((await handler(req("/v1/responses", "POST", validBody("planner"), invite), env)).status, 200);
  let response = await handler(req("/v1/responses", "POST", validBody("planner"), invite), env);
  assert.equal(response.status, 429); assert.equal((await response.json()).limit, "monthly_runs");
  await handler(req("/v1/responses", "POST", validBody("triage"), invite), env);
  response = await handler(req("/v1/responses", "POST", validBody("triage"), invite), env);
  assert.equal(response.status, 429); assert.equal((await response.json()).limit, "daily_requests");
});

test("event validation, daily aggregation, and admin metrics authorization", async () => {
  const usage = kv(), handler = createHandler(), env = { AK14_USAGE: usage, INVITE_TOKEN_HASHES: inviteHash, ADMIN_TOKEN: "secret-admin" };
  const batch = [{ name: "generation_started", ts: new Date().toISOString(), props: { screen: "home", count: 2 } }, { name: "generation_started", ts: new Date().toISOString(), props: {} }];
  assert.equal((await handler(req("/v1/events", "POST", { events: batch }, invite), env)).status, 202);
  assert.equal((await handler(req("/v1/events", "POST", [{ name: "unknown", ts: new Date().toISOString(), props: {} }], invite), env)).status, 400);
  assert.equal((await handler(req("/v1/events", "POST", [{ name: "app_opened", ts: new Date().toISOString(), props: { photo: "data" } }], invite), env)).status, 400);
  assert.equal((await handler(req("/v1/admin/metrics?days=1", "GET"), env)).status, 401);
  const metrics = await handler(req("/v1/admin/metrics?days=1", "GET", undefined, "secret-admin"), env);
  assert.equal(metrics.status, 200); const data = await metrics.json();
  assert.equal(data.daily[0].counts.generation_started, 2);
});
