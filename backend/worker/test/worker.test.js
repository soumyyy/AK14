import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createHandler } from "../src/index.js";

const signingKey = "local-test-signing-key-32-bytes-minimum";
function token(sub = "P01") {
  const payload = Buffer.from(JSON.stringify({ v: 1, scope: "responses", sub,
    exp: Math.floor(Date.now() / 1000) + 3600 })).toString("base64url");
  return `${payload}.${createHmac("sha256", signingKey).update(payload).digest("base64url")}`;
}
const env = {
  OPENAI_API_KEY: "upstream-test-key",
  INVITE_SIGNING_KEY: signingKey,
  MODEL_LIMIT: { limit: async () => ({ success: true }) },
};
function body() {
  return {
    model: "gpt-6-luna", store: false, max_output_tokens: 16000,
    reasoning: { effort: "low" },
    text: { format: { type: "json_schema", name: "triage", strict: true, schema: { type: "object" } } },
    input: [{ role: "system", content: "System" },
      { role: "user", content: [{ type: "input_text", text: "Photo" },
        { type: "input_image", image_url: "data:image/jpeg;base64,AA==", detail: "high" }] }],
  };
}
function request(value = body(), auth = token()) {
  return new Request("https://ak14.example/v1/responses", { method: "POST",
    headers: { authorization: `Bearer ${auth}`, "content-type": "application/json" },
    body: JSON.stringify(value) });
}

test("forwards a bounded signed request and returns provider response", async () => {
  let seen;
  const handler = createHandler(async (url, options) => {
    seen = { url, options };
    return Response.json({ status: "completed", output: [] });
  });
  const response = await handler(request(), env);
  assert.equal(response.status, 200);
  assert.equal(seen.url, "https://api.openai.com/v1/responses");
  assert.equal(seen.options.headers.authorization, "Bearer upstream-test-key");
  assert.equal(JSON.parse(seen.options.body).store, false);
  assert.equal((await response.json()).status, "completed");
});

test("rejects unsigned requests, unsupported model calls, and rate limit", async () => {
  const handler = createHandler(async () => { throw new Error("must not forward"); });
  assert.equal((await handler(request(body(), "bad-token"), env)).status, 401);
  const altered = body(); altered.model = "gpt-6-astra";
  assert.equal((await handler(request(altered), env)).status, 400);
  const stored = body(); stored.store = true;
  assert.equal((await handler(request(stored), env)).status, 400);
  assert.equal((await handler(request(), { ...env, MODEL_LIMIT: { limit: async () => ({ success: false }) } })).status, 429);
});

test("rejects a streamed body over the limit before parsing or forwarding it", async () => {
  const handler = createHandler(async () => { throw new Error("must not forward"); });
  const chunk = new Uint8Array(2 * 1024 * 1024);
  const stream = new ReadableStream({
    start(controller) {
      for (let i = 0; i < 4; i++) controller.enqueue(chunk);
      controller.enqueue(new Uint8Array([0]));
      controller.close();
    },
  });
  const oversized = new Request("https://ak14.example/v1/responses", {
    method: "POST", headers: { authorization: `Bearer ${token()}` }, body: stream, duplex: "half",
  });
  const response = await handler(oversized, env);
  assert.equal(response.status, 413);
});

test("serves a versioned style config matching the bundled style pack", async () => {
  const handler = createHandler();
  const response = await handler(new Request("https://ak14.example/v1/config"), env);
  assert.equal(response.status, 200);
  const config = await response.json();
  const bundled = JSON.parse(await readFile(new URL("../../../Sources/Render/Resources/StylePacks/starter-editorial.json", import.meta.url)));
  assert.deepEqual(config.stylePacks[0], bundled);
  assert.equal(response.headers.get("etag"), '"starter-editorial-1.0.0-config-1"');
});
