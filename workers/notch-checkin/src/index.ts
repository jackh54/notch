// Counts which versions of the Agent Notch fork are installed.
//
// The app sends a random install ID and its version once a day, if the user allows it. That is
// all that is kept: never read or store IP addresses here, apart from passing one to the rate
// limiter, which doesn't keep it either. Sparkle updates don't go through this Worker, so
// updates keep working when it is down.

import { Hono } from "hono";

type Env = {
	DB: D1Database;
	CHECKIN_LIMITER: RateLimit;
	STATS_TOKEN: string;
};

const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const VERSION = /^[0-9A-Za-z.+-]{1,32}$/;
// Fork releases append the CI run number, as in "271.5".
const BUILD = /^[0-9]+(\.[0-9]+)*$/;
const BUILD_MAX_LENGTH = 32;

const DAY = 24 * 60 * 60 * 1000;
/** Installs that stop checking in are forgotten after this long. */
const RETENTION = 180 * DAY;

const app = new Hono<{ Bindings: Env }>();

/** True when the caller is over the limit. Limits by IP so random IDs can't fill the table. */
async function isLimited(c: { env: Env; req: { header(name: string): string | undefined } }) {
	const key = c.req.header("cf-connecting-ip") ?? "unknown";
	const { success } = await c.env.CHECKIN_LIMITER.limit({ key });
	return !success;
}

app.post("/checkin", async (c) => {
	if (await isLimited(c)) return c.body(null, 429);

	const body = await c.req.json<Record<string, unknown>>().catch(() => null);
	const { installId, version, build } = body ?? {};
	if (
		typeof installId !== "string" || !INSTALL_ID.test(installId) ||
		typeof version !== "string" || !VERSION.test(version) ||
		typeof build !== "string" || build.length > BUILD_MAX_LENGTH || !BUILD.test(build)
	) {
		return c.body(null, 400);
	}

	const now = Date.now();
	await c.env.DB.prepare(
		`INSERT INTO installs (install_id, version, build, first_seen, last_seen)
		 VALUES (?1, ?2, ?3, ?4, ?4)
		 ON CONFLICT (install_id) DO UPDATE SET
		   version = excluded.version, build = excluded.build, last_seen = excluded.last_seen`,
	).bind(installId, version, build, now).run();

	return c.body(null, 204);
});

// Sent by older releases when the user turns sharing off. Knowing the random ID is the only proof needed.
app.delete("/installs/:id", async (c) => {
	if (await isLimited(c)) return c.body(null, 429);

	const id = c.req.param("id");
	if (!INSTALL_ID.test(id)) return c.body(null, 400);

	await c.env.DB.prepare("DELETE FROM installs WHERE install_id = ?1").bind(id).run();
	return c.body(null, 204);
});

/** Newest first, comparing each dotted part as a number so 271.10 beats 271.9. */
function compareBuilds(a: string, b: string) {
	const left = a.split(".").map(Number);
	const right = b.split(".").map(Number);
	for (let i = 0; i < Math.max(left.length, right.length); i++) {
		const difference = (right[i] ?? 0) - (left[i] ?? 0);
		if (difference !== 0) return difference;
	}
	return 0;
}

async function isAuthorized(header: string | undefined, token: string | undefined) {
	if (!token) return false;
	const encoder = new TextEncoder();
	const [given, expected] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(header ?? "")),
		crypto.subtle.digest("SHA-256", encoder.encode(`Bearer ${token}`)),
	]);
	return crypto.subtle.timingSafeEqual(given, expected);
}

app.get("/stats", async (c) => {
	if (!(await isAuthorized(c.req.header("authorization"), c.env.STATS_TOKEN))) {
		return c.body(null, 401);
	}

	const now = Date.now();
	const weekAgo = now - 7 * DAY;
	const [versions, installs] = await c.env.DB.batch([
		c.env.DB.prepare(
			`SELECT version, build, COUNT(*) AS installs, SUM(last_seen >= ?1) AS activeLast7Days
			 FROM installs GROUP BY version, build`,
		).bind(weekAgo),
		c.env.DB.prepare(
			`SELECT substr(install_id, 1, 8) AS id, version, build,
			        first_seen AS firstSeen, last_seen AS lastSeen
			 FROM installs ORDER BY last_seen DESC`,
		),
	]);

	const rows = (installs?.results ?? []) as { lastSeen: number; firstSeen: number }[];
	return c.json({
		total: rows.length,
		activeLast7Days: rows.filter((row) => row.lastSeen >= weekAgo).length,
		versions: ((versions?.results ?? []) as { build: string }[]).sort((a, b) => compareBuilds(a.build, b.build)),
		installs: rows.map((row) => ({
			...row,
			firstSeen: new Date(row.firstSeen).toISOString(),
			lastSeen: new Date(row.lastSeen).toISOString(),
		})),
	});
});

export default {
	fetch: app.fetch,

	async scheduled(_event: ScheduledController, env: Env) {
		await env.DB.prepare("DELETE FROM installs WHERE last_seen < ?1")
			.bind(Date.now() - RETENTION)
			.run();
	},
} satisfies ExportedHandler<Env>;
