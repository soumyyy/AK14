import styleConfig from "./style-config.json" with { type: "json" };

const encoder = new TextEncoder();
const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_PARTS = 100;
const ALLOWED_SCHEMAS = new Set(["triage", "triage_repair", "planner", "repair", "retry", "occasion_split"]);
const EVENT_NAMES = new Set(["app_opened", "moment_suggested", "generation_started", "generation_completed", "generation_failed", "option_selected", "editor_opened", "design_exported", "carousel_shared", "carousel_saved", "onboarding_completed", "paywall_viewed"]);
const FUNNEL = ["generation_started", "generation_completed", "option_selected", ["design_exported", "carousel_shared", "carousel_saved"]];

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extraHeaders } });
}
function hex(bytes) { return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join(""); }
async function sha256(value) { return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)))); }
async function sha256Bytes(value) { return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", value))); }
function utcDate(date = new Date()) { return date.toISOString().slice(0, 10); }
function nextUtcDay(date = new Date()) { const d = new Date(date); d.setUTCHours(24, 0, 0, 0); return d.toISOString(); }
function nextUtcMonth(date = new Date()) { return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1)).toISOString(); }
function capValue(value) { const number = Number(value); return Number.isFinite(number) && number > 0 ? number : 0; }
async function readNumber(kv, key) { return Number(await kv.get(key) || 0); }
function estimateCost(usage = {}) {
  const input = Number(usage.input_tokens) || 0, cached = Number(usage.input_tokens_details?.cached_tokens) || 0, output = Number(usage.output_tokens) || 0;
  return { input, cached, output, usd: Math.max(0, input - cached) * 0.10 / 1_000_000 + cached * 0.01 / 1_000_000 + output * 0.50 / 1_000_000 };
}

async function authenticate(request, env) {
  const auth = request.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  const token = auth.slice(7);
  if (!token || token.length > 512) return null;
  const hash = await sha256(token);
  const configured = (env.INVITE_TOKEN_HASHES || "").split(",").map(value => value.trim().toLowerCase());
  if (configured.includes(hash)) return { id: hash, type: "invite" };
  const raw = await env.AK14_USAGE?.get(`session:${hash}`);
  if (!raw) return null;
  try {
    const session = JSON.parse(raw);
    if (!Number.isFinite(session.expiresAt) || session.expiresAt <= Date.now()) return null;
    return { id: session.userID, type: "session" };
  } catch { return null; }
}

async function appleKeys(env, fresh = false) {
  const cacheKey = "apple:jwks";
  const cached = fresh ? null : await env.AK14_USAGE.get(cacheKey);
  if (cached) { try { return JSON.parse(cached); } catch {} }
  const response = await (env.fetchAppleJWKS || fetch)("https://appleid.apple.com/auth/keys");
  if (!response.ok) throw new Error("Apple key fetch failed");
  const keys = await response.json();
  if (!Array.isArray(keys.keys)) throw new Error("Invalid Apple keys");
  await env.AK14_USAGE.put(cacheKey, JSON.stringify(keys), { expirationTtl: 86400 });
  return keys;
}

async function verifyAppleToken(token, env) {
  if (typeof token !== "string" || token.length > 8192) throw new Error("Invalid identity token");
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("Invalid identity token");
  const decode = part => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  const header = decode(parts[0]), claims = decode(parts[1]);
  if (header.alg !== "RS256" || !header.kid || claims.iss !== "https://appleid.apple.com" || claims.aud !== (env.APPLE_BUNDLE_ID || "com.ak14.app")
    || !Number.isFinite(claims.exp) || claims.exp <= Math.floor(Date.now() / 1000) || typeof claims.sub !== "string" || !claims.sub) throw new Error("Invalid Apple identity token");
  const findKey = keys => keys.keys.find(key => key.kid === header.kid && key.kty === "RSA");
  // Apple rotates signing keys: refetch once when the cached set lacks this key ID.
  const jwk = findKey(await appleKeys(env)) || findKey(await appleKeys(env, true));
  if (!jwk) throw new Error("Apple signing key not found");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signature = Uint8Array.from(atob(parts[2].replace(/-/g, "+").replace(/_/g, "/")), char => char.charCodeAt(0));
  if (!await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, encoder.encode(`${parts[0]}.${parts[1]}`))) throw new Error("Invalid Apple signature");
  return claims.sub;
}

function validRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return false;
  const allowed = ["model", "input", "text", "reasoning", "max_output_tokens", "store"];
  if (Object.keys(body).some(key => !allowed.includes(key))) return false;
  if (body.model !== "gpt-6-luna" || body.store !== false || !Number.isInteger(body.max_output_tokens) || body.max_output_tokens < 1 || body.max_output_tokens > 16000) return false;
  if (!["low", "medium"].includes(body.reasoning?.effort)) return false;
  const format = body.text?.format;
  if (format?.type !== "json_schema" || format.strict !== true || !ALLOWED_SCHEMAS.has(format.name) || !format.schema || typeof format.schema !== "object") return false;
  if (!Array.isArray(body.input) || body.input.length !== 2 || body.input[0]?.role !== "system" || typeof body.input[0]?.content !== "string" || body.input[0].content.length > 30000 || body.input[1]?.role !== "user" || !Array.isArray(body.input[1]?.content)) return false;
  let images = 0;
  for (const part of body.input[1].content) {
    if (part?.type === "input_text") { if (typeof part.text !== "string" || part.text.length > 30000) return false; }
    else if (part?.type === "input_image") { images++; if (!["low", "high"].includes(part.detail) || typeof part.image_url !== "string" || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(part.image_url) || part.image_url.length > 350000) return false; }
    else return false;
  }
  return images <= MAX_IMAGE_PARTS;
}

async function readBoundedBody(request) {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader(), chunks = []; let size = 0;
  try { while (true) { const { value, done } = await reader.read(); if (done) break; size += value.byteLength; if (size > MAX_BODY_BYTES) { await reader.cancel().catch(() => {}); return null; } chunks.push(value); } }
  finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; } return bytes;
}

function validEvents(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) return false;
  return value.every(event => {
    if (!event || typeof event !== "object" || Array.isArray(event) || !EVENT_NAMES.has(event.name) || !Number.isFinite(Date.parse(event.ts)) || !event.props || typeof event.props !== "object" || Array.isArray(event.props)) return false;
    const entries = Object.entries(event.props);
    return entries.length <= 12 && entries.every(([key, item]) => typeof key === "string" && !/(photo|image|base64|data)/i.test(key) && ((typeof item === "string" && item.length <= 64 && !/^data:image\//i.test(item)) || (typeof item === "number" && Number.isFinite(item))));
  });
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
      const bytes = await env.AK14_ASSETS.get(assetMatch[1], "arrayBuffer"); if (bytes === null) return json({ error: "not found" }, 404);
      if (await sha256Bytes(bytes) !== assetMatch[1]) return json({ error: "asset integrity check failed" }, 500);
      return new Response(bytes, { headers: { "content-type": "image/jpeg", "cache-control": "public, max-age=31536000, immutable" } });
    }
    if (request.method === "POST" && url.pathname === "/v1/auth/apple") {
      if (!env.AK14_USAGE || !env.APPLE_BUNDLE_ID) return json({ error: "server is not configured" }, 503);
      let data; try { data = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      try {
        const sub = await verifyAppleToken(data?.identityToken, env), userID = await sha256(sub);
        const sessionToken = hex(crypto.getRandomValues(new Uint8Array(32))), tokenHash = await sha256(sessionToken);
        const expiresAt = Date.now() + 30 * 86400_000;
        await env.AK14_USAGE.put(`session:${tokenHash}`, JSON.stringify({ userID, createdAt: Date.now(), expiresAt }), { expirationTtl: 30 * 86400 });
        return json({ sessionToken, expiresAt: new Date(expiresAt).toISOString() });
      } catch { return json({ error: "invalid Apple identity token" }, 401); }
    }
    if (request.method === "GET" && url.pathname === "/v1/admin/metrics") {
      if (!env.ADMIN_TOKEN || request.headers.get("authorization") !== `Bearer ${env.ADMIN_TOKEN}`) return json({ error: "unauthorized" }, 401);
      if (!env.AK14_USAGE) return json({ error: "server is not configured" }, 503);
      const days = Math.max(1, Math.min(90, Number(url.searchParams.get("days")) || 7)), daily = [];
      for (let offset = days - 1; offset >= 0; offset--) {
        const date = new Date(); date.setUTCDate(date.getUTCDate() - offset); const day = utcDate(date), counts = {};
        for (const name of EVENT_NAMES) counts[name] = await readNumber(env.AK14_USAGE, `event:${day}:${name}`);
        daily.push({ day, counts, funnel: { generation_started: counts.generation_started, generation_completed: counts.generation_completed, option_selected: counts.option_selected, exported_or_shared_or_saved: counts.design_exported + counts.carousel_shared + counts.carousel_saved } });
      }
      return json({ daily });
    }
    if (!["/v1/responses", "/v1/events"].includes(url.pathname)) return json({ error: "not found" }, 404);
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST" });
    let user; try { user = await authenticate(request, env); } catch { return json({ error: "server is not configured" }, 503); }
    if (!user) return json({ error: "unauthorized" }, 401);
    if (url.pathname === "/v1/events") {
      let batch; try { batch = await request.json(); } catch { return json({ error: "invalid JSON" }, 400); }
      const events = Array.isArray(batch) ? batch : batch?.events;
      if (!validEvents(events)) return json({ error: "invalid events" }, 400);
      const totals = new Map();
      for (const event of events) { const day = utcDate(new Date(event.ts)), key = `event:${day}:${event.name}`; totals.set(key, (totals.get(key) || 0) + 1); }
      for (const [key, amount] of totals) await env.AK14_USAGE.put(key, String(await readNumber(env.AK14_USAGE, key) + amount), { expirationTtl: 400 * 86400 });
      console.log(JSON.stringify({ event: "analytics_batch", user_id_hash: user.id, count: events.length }));
      return json({ accepted: events.length }, 202);
    }
    if (!env.OPENAI_API_KEY) return json({ error: "server is not configured" }, 503);
    const declaredSize = Number(request.headers.get("content-length") || 0); if (declaredSize > MAX_BODY_BYTES) return json({ error: "request too large" }, 413);
    let bytes; try { bytes = await readBoundedBody(request); } catch { return json({ error: "invalid request body" }, 400); }
    if (!bytes) return json({ error: "request too large" }, 413);
    let body; try { body = JSON.parse(new TextDecoder().decode(bytes)); } catch { return json({ error: "invalid JSON" }, 400); }
    if (!validRequest(body)) return json({ error: "unsupported request" }, 400);
    const now = new Date(), day = utcDate(now), month = day.slice(0, 7), prefix = `${user.id}:${day}`, requestsKey = `${prefix}:requests`, spendKey = `${prefix}:spend`, monthlyKey = `${user.id}:${month}:planner_runs`;
    const requestCount = await readNumber(env.AK14_USAGE, requestsKey), spend = await readNumber(env.AK14_USAGE, spendKey), monthlyRuns = await readNumber(env.AK14_USAGE, monthlyKey);
    const requestCap = capValue(env.DAILY_REQUEST_CAP), spendCap = capValue(env.DAILY_SPEND_CAP_USD), monthlyCap = capValue(env.MONTHLY_RUN_CAP) || 60;
    let limit = null, resetsAt;
    if (requestCap && requestCount >= requestCap) { limit = "daily_requests"; resetsAt = nextUtcDay(now); }
    else if (spendCap && spend >= spendCap) { limit = "daily_spend"; resetsAt = nextUtcDay(now); }
    else if (body.text.format.name === "planner" && monthlyRuns >= monthlyCap) { limit = "monthly_runs"; resetsAt = nextUtcMonth(now); }
    if (limit) return json({ error: "usage limit reached", limit, resetsAt }, 429);
    await env.AK14_USAGE.put(requestsKey, String(requestCount + 1), { expirationTtl: 172800 });
    if (body.text.format.name === "planner") await env.AK14_USAGE.put(monthlyKey, String(monthlyRuns + 1), { expirationTtl: 32 * 86400 });
    let upstream; try { upstream = await fetchUpstream("https://api.openai.com/v1/responses", { method: "POST", headers: { authorization: `Bearer ${env.OPENAI_API_KEY}`, "content-type": "application/json" }, body: JSON.stringify(body) }); }
    catch { return json({ error: "model service unavailable" }, 502); }
    let responseBody; try { responseBody = await upstream.text(); } catch { responseBody = ""; }
    let usage = {}; try { usage = JSON.parse(responseBody).usage || {}; } catch {}
    const cost = estimateCost(usage); await env.AK14_USAGE.put(spendKey, String(spend + cost.usd), { expirationTtl: 172800 });
    console.log(JSON.stringify({ event: "model_usage", user_id_hash: user.id, model: body.model, input_tokens: cost.input, cached_tokens: cost.cached, output_tokens: cost.output, estimated_usd: cost.usd }));
    return new Response(responseBody, { status: upstream.status, headers: { "content-type": upstream.headers.get("content-type") || "application/json", "cache-control": "no-store" } });
  };
}
export default { fetch: createHandler() };
