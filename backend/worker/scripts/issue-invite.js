import { createHash, randomBytes } from "node:crypto";

const token = randomBytes(32).toString("base64url");
const hash = createHash("sha256").update(token).digest("hex");
process.stdout.write(`Invite (give to user once): ${token}\nSHA-256 (store in INVITE_TOKEN_HASHES): ${hash}\n`);
