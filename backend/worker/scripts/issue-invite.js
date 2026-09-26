import { createHmac, randomBytes } from "node:crypto";

const [sub, durationDays = "7"] = process.argv.slice(2);
const key = process.env.INVITE_SIGNING_KEY;
if (!/^[A-Za-z0-9_-]{1,64}$/.test(sub || "") || !key || Buffer.byteLength(key) < 32) {
  console.error("Usage: INVITE_SIGNING_KEY=<32+ byte secret> node scripts/issue-invite.js <pseudonymous-id> [days:1-31]");
  process.exit(1);
}
const days = Number(durationDays);
if (!Number.isInteger(days) || days < 1 || days > 31) {
  console.error("days must be 1–31");
  process.exit(1);
}
const payload = Buffer.from(JSON.stringify({ v: 1, scope: "responses", sub,
  exp: Math.floor(Date.now() / 1000) + days * 86400, nonce: randomBytes(8).toString("hex") })).toString("base64url");
const signature = createHmac("sha256", key).update(payload).digest("base64url");
process.stdout.write(`${payload}.${signature}\n`);
