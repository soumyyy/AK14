import styleConfig from "./style-config.json" with { type: "json" };

const encoder = new TextEncoder();
const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_PARTS = 100;
const ALLOWED_SCHEMAS = new Set(["triage", "triage_repair", "planner", "repair", "retry"]);

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extraHeaders },
  });
}

function decodeBase64URL(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid token encoding");
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")), c => c.charCodeAt(0));
}

async function verifyInvite(authorization, signingKey) {
  if (!signingKey || encoder.encode(signingKey).length < 32) throw new Error("server signing key is missing or too short");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7);
  if (token.length > 2048) return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  try {
    const key = await crypto.subtle.importKey("raw", encoder.encode(signingKey),
      { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const valid = await crypto.subtle.verify("HMAC", key, decodeBase64URL(parts[1]), encoder.encode(parts[0]));
    if (!valid) return null;
    const invite = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[0])));
    const now = Math.floor(Date.now() / 1000);
    if (invite.v !== 1 || invite.scope !== "responses" || !/^[A-Za-z0-9_-]{1,64}$/.test(invite.sub)
      || !Number.isInteger(invite.exp) || invite.exp <= now || invite.exp > now + 31 * 86400) return null;
    return invite;
  } catch {
    return null;
  }
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
    if (url.pathname !== "/v1/responses") return json({ error: "not found" }, 404);
    if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST" });
    if (!env.OPENAI_API_KEY) return json({ error: "server is not configured" }, 503);
    let invite;
    try { invite = await verifyInvite(request.headers.get("authorization"), env.INVITE_SIGNING_KEY); }
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
    const limit = await env.MODEL_LIMIT.limit({ key: invite.sub });
    if (!limit.success) return json({ error: "rate limit exceeded" }, 429);
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
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") || "application/json", "cache-control": "no-store" },
    });
  };
}

export default { fetch: createHandler() };
