import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename, resolve } from "node:path";

const file = process.argv[2];
if (!file) {
  console.error("Usage: node scripts/put-asset.js <file>");
  process.exitCode = 1;
} else {
  const path = resolve(file);
  const bytes = await readFile(path);
  const hash = createHash("sha256").update(bytes).digest("hex");
  const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
  console.log(`npx wrangler kv key put --binding AK14_ASSETS ${hash} --path ${shellQuote(path)} --metadata ${shellQuote('{"contentType":"image/jpeg"}')}`);
}
