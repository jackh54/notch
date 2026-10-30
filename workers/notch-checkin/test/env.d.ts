declare namespace Cloudflare {
	interface Env {
		DB: D1Database;
		CHECKIN_LIMITER: RateLimit;
		STATS_TOKEN: string;
		TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
	}
}
