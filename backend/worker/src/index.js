import styleConfig from "./style-config.json" with { type: "json" };

const encoder = new TextEncoder();
const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_PARTS = 100;
const ALLOWED_SCHEMAS = new Set(["triage", "triage_repair", "planner", "repair", "retry", "occasion_split"]);

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extraHeaders },
  });
}

async function verifyInvite(authorization, tokenHashes) {
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7);
  if (!token || token.length > 512) return null;
  try {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(token)));
    const hash = [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const configured = (tokenHashes || "").split(",").map(value => value.trim().toLowerCase());
    return configured.includes(hash) ? { id: hash } : null;
  } catch {
    return null;
  }
}

function utcDate() { return new Date().toISOString().slice(0, 10); }
function capValue(value) { const number = Number(value); return Number.isFinite(number) && number > 0 ? number : 0; }
async function readNumber(kv, key) { return Number(await kv.get(key) || 0); }
function estimateCost(usage = {}) {
  const input = Number(usage.input_tokens) || 0;
  const cached = Number(usage.input_tokens_details?.cached_tokens) || 0;
  const output = Number(usage.output_tokens) || 0;
  const billableInput = Math.max(0, input - cached);
  return { input, cached, output, usd: billableInput * 0.10 / 1_000_000 + cached * 0.01 / 1_000_000 + output * 0.50 / 1_000_000 };
}

function validRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return false;
  const allowed = ["model", "input", "text", "reasoning", "max_output_tokens", "store"];
  if (Object.keys(body).some(key => !allowed.includes(key))) return false;
  if (body.model !== "gpt-6-luna" || body.store !== false || !Number.isInteger(body.max_output_tokens)
    || body.max_output_tokens < 1 || body.max_output_tokens > 16000) return false;
  if (!["low", "medium"].includes(body.reasoning?.effort)) return false;
  const format = body.text?.format;
  if (format?.type !== "json_schema" || format.strict !== true || !ALLOWED_SCHEMAS.has(format.name)
    || !format.schema || typeof format.schema !== "object") return false;
  if (!Array.isArray(body.input) || body.input.length !== 2 || body.input[0]?.role !== "system"
    || typeof body.input[0]?.content !== "string" || body.input[0].content.length > 30000
    || body.input[1]?.role !== "user" || !Array.isArray(body.input[1]?.content)) return false;
  let images = 0;
  for (const part of body.input[1].content) {
    if (part?.type === "input_text") {
      if (typeof part.text !== "string" || part.text.length > 30000) return false;
    } else if (part?.type === "input_image") {
      images++;
      if (!["low", "high"].includes(part.detail) || typeof part.image_url !== "string"
        || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(part.image_url)
        || part.image_url.length > 350000) return false;
    } else return false;
  }
  return images <= MAX_IMAGE_PARTS;
}

async function readBoundedBody(request) {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export function createHandler(fetchUpstream = fetch) {
  return async function handle(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
    if (request.method === "GET" && url.pathname === "/v1/config") {
      const etag = '"starter-editorial-1.0.0-config-1"';
      if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers: { etag } });
      return json(styleConfig, 200, { etag, "cache-control": "public, max-age=300" });
    }
    const assetMatch = url.pathname.match(/^\/v1\/assets\/([a-f0-9]{64})$/);
    if (request.method === "GET" && assetMatch) {
      if (!env.AK14_ASSETS) return json({ error: "not found" }, 404);
      const bytes = await env.AK14_ASSETS.get(assetMatch[1], "arrayBuffer");
      if (bytes === null) return json({ error: "not found" }, 404);
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
      const hash = [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
      if (hash !== assetMatch[1]) return json({ error: "asset integrity check failed" }, 500);
      return new Response(bytes, { headers: {
        "content-type": "image/jpeg", "cache-control": "public, max-age=31536000, immutable",
      } });
    }
    if (url.pathname !== "/v1/responses") return json({ error: "not found" }, 404);
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST" });
    if (!env.OPENAI_API_KEY) return json({ error: "server is not configured" }, 503);
    let invite;
    try { invite = await verifyInvite(request.headers.get("authorization"), env.INVITE_TOKEN_HASHES); }
    catch { return json({ error: "server is not configured" }, 503); }
    if (!invite) return json({ error: "unauthorized" }, 401);
    const declaredSize = Number(request.headers.get("content-length") || 0);
    if (declaredSize > MAX_BODY_BYTES) return json({ error: "request too large" }, 413);
    let bytes;
    try { bytes = await readBoundedBody(request); }
    catch { return json({ error: "invalid request body" }, 400); }
    if (!bytes) return json({ error: "request too large" }, 413);
    let body;
    try { body = JSON.parse(new TextDecoder().decode(bytes)); }
    catch { return json({ error: "invalid JSON" }, 400); }
    if (!validRequest(body)) return json({ error: "unsupported request" }, 400);
    if (!env.AK14_USAGE) return json({ error: "server is not configured" }, 503);
    const date = utcDate();
    const prefix = `${invite.id}:${date}`;
    const requestsKey = `${prefix}:requests`;
    const spendKey = `${prefix}:spend`;
    const requestCount = await readNumber(env.AK14_USAGE, requestsKey);
    const spend = await readNumber(env.AK14_USAGE, spendKey);
    const requestCap = capValue(env.DAILY_REQUEST_CAP);
    const spendCap = capValue(env.DAILY_SPEND_CAP_USD);
    if ((requestCap && requestCount >= requestCap) || (spendCap && spend >= spendCap)) {
      return json({ error: "daily usage limit reached" }, 429);
    }
    await env.AK14_USAGE.put(requestsKey, String(requestCount + 1), { expirationTtl: 172800 });
    let upstream;
    try {
      upstream = await fetchUpstream("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: { authorization: `Bearer ${env.OPENAI_API_KEY}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    } catch {
      return json({ error: "model service unavailable" }, 502);
    }
    let responseBody;
    try { responseBody = await upstream.text(); } catch { responseBody = ""; }
    let usage = {};
    try { usage = JSON.parse(responseBody).usage || {}; } catch {}
    const cost = estimateCost(usage);
    await env.AK14_USAGE.put(spendKey, String(spend + cost.usd), { expirationTtl: 172800 });
    console.log(JSON.stringify({ event: "model_usage", token_id_hash: invite.id, model: body.model,
      input_tokens: cost.input, cached_tokens: cost.cached, output_tokens: cost.output, estimated_usd: cost.usd }));
    return new Response(responseBody, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") || "application/json", "cache-control": "no-store" },
    });
  };
}

export default { fetch: createHandler() };
