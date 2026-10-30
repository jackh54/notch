// Stops a deploy that would break this Worker's privacy promises or isn't set up yet.
import { readFileSync } from "node:fs";

const text = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");
const config = JSON.parse(text.replace(/^\s*\/\/.*$/gm, ""));

const failures = [];
if (config.observability?.logs?.invocation_logs !== false) failures.push("invocation_logs must be false");
if (config.preview_urls !== false) failures.push("preview_urls must be false");
if (/^0+(-0+)*$/.test(config.d1_databases?.[0]?.database_id ?? "")) {
	failures.push("set database_id from `wrangler d1 create notch-checkin`");
}

if (failures.length > 0) {
	console.error(`Deploy blocked:\n- ${failures.join("\n- ")}`);
	process.exit(1);
}
