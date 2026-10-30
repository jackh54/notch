import { applyD1Migrations, env, SELF } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";

const ID = "3f2a9c10-7b4e-4d21-9a6f-0c1d2e3f4a5b";
const OTHER_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const URL_BASE = "https://notch.test";
const DAY = 24 * 60 * 60 * 1000;

let nextIP = 0;

/** Each call gets its own IP unless told otherwise, so tests don't trip the rate limit. */
function checkIn(body: unknown, ip = `10.0.0.${++nextIP}`) {
	return SELF.fetch(`${URL_BASE}/checkin`, {
		method: "POST",
		headers: { "content-type": "application/json", "cf-connecting-ip": ip },
		body: JSON.stringify(body),
	});
}

function stats(token = env.STATS_TOKEN) {
	return SELF.fetch(`${URL_BASE}/stats`, { headers: { authorization: `Bearer ${token}` } });
}

async function row(id: string) {
	return env.DB.prepare("SELECT * FROM installs WHERE install_id = ?1").bind(id).first<Record<string, unknown>>();
}

beforeAll(async () => {
	await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
	await env.DB.prepare("DELETE FROM installs").run();
});

describe("POST /checkin", () => {
	it("records a new install", async () => {
		const response = await checkIn({ installId: ID, version: "2.7.3", build: "271" });

		expect(response.status).toBe(204);
		expect(await row(ID)).toMatchObject({ version: "2.7.3", build: "271" });
	});

	it("updates the version and keeps first_seen on a later check-in", async () => {
		await checkIn({ installId: ID, version: "2.7.3", build: "271" });
		const first = await row(ID);

		await new Promise((resolve) => setTimeout(resolve, 5));
		await checkIn({ installId: ID, version: "2.7.4", build: "272" });
		const second = await row(ID);

		expect(second).toMatchObject({ version: "2.7.4", build: "272", first_seen: first?.first_seen });
		expect(second?.last_seen as number).toBeGreaterThan(first?.last_seen as number);
	});

	it("accepts the dotted build numbers fork releases use", async () => {
		const response = await checkIn({ installId: ID, version: "2.7.3", build: "271.5" });

		expect(response.status).toBe(204);
		expect(await row(ID)).toMatchObject({ build: "271.5" });
	});

	it("stores nothing beyond the known fields", async () => {
		await checkIn({ installId: ID, version: "2.7.3", build: "271", name: "Jack" }, "203.0.113.9");

		expect(Object.keys((await row(ID)) ?? {}).sort()).toEqual(
			["build", "first_seen", "install_id", "last_seen", "version"],
		);
		expect(JSON.stringify(await row(ID))).not.toContain("203.0.113.9");
	});

	it.each([
		["a short ID", { installId: "abc", version: "2.7.3", build: "271" }],
		["an uppercase ID", { installId: ID.toUpperCase(), version: "2.7.3", build: "271" }],
		["a missing version", { installId: ID, build: "271" }],
		["a version with spaces", { installId: ID, version: "2.7 3", build: "271" }],
		["a non-numeric build", { installId: ID, version: "2.7.3", build: "x" }],
		["a build with an empty part", { installId: ID, version: "2.7.3", build: "271." }],
		["an overlong build", { installId: ID, version: "2.7.3", build: "1".repeat(33) }],
	])("rejects %s", async (_name, body) => {
		expect((await checkIn(body)).status).toBe(400);
		expect(await row(ID)).toBeNull();
	});

	it("rejects a body that isn't JSON", async () => {
		const response = await SELF.fetch(`${URL_BASE}/checkin`, {
			method: "POST",
			headers: { "cf-connecting-ip": "10.1.0.1" },
			body: "not json",
		});
		expect(response.status).toBe(400);
	});

	it("limits repeated requests from one address", async () => {
		const statuses: number[] = [];
		for (let i = 0; i < 15; i++) {
			statuses.push((await checkIn({ installId: ID, version: "2.7.3", build: "271" }, "10.2.0.1")).status);
		}
		expect(statuses).toContain(204);
		expect(statuses).toContain(429);
	});
});

describe("DELETE /installs/:id", () => {
	it("forgets the install", async () => {
		await checkIn({ installId: ID, version: "2.7.3", build: "271" });

		const response = await SELF.fetch(`${URL_BASE}/installs/${ID}`, {
			method: "DELETE",
			headers: { "cf-connecting-ip": "10.3.0.1" },
		});

		expect(response.status).toBe(204);
		expect(await row(ID)).toBeNull();
	});

	it("rejects anything that isn't an install ID", async () => {
		const response = await SELF.fetch(`${URL_BASE}/installs/abc`, {
			method: "DELETE",
			headers: { "cf-connecting-ip": "10.3.0.2" },
		});
		expect(response.status).toBe(400);
	});
});

describe("GET /stats", () => {
	it("needs the token", async () => {
		expect((await SELF.fetch(`${URL_BASE}/stats`)).status).toBe(401);
		expect((await stats("wrong")).status).toBe(401);
	});

	it("groups installs by version, newest build first, and shortens IDs", async () => {
		await checkIn({ installId: ID, version: "2.7.3", build: "271.9" });
		await checkIn({ installId: OTHER_ID, version: "2.7.3", build: "271.10" });
		await env.DB.prepare("UPDATE installs SET last_seen = ?1 WHERE install_id = ?2")
			.bind(Date.now() - 10 * DAY, ID)
			.run();

		const body = await (await stats()).json<{
			total: number;
			activeLast7Days: number;
			versions: { build: string; installs: number; activeLast7Days: number }[];
			installs: { id: string }[];
		}>();

		expect(body.total).toBe(2);
		expect(body.activeLast7Days).toBe(1);
		expect(body.versions.map((version) => version.build)).toEqual(["271.10", "271.9"]);
		expect(body.versions[1]).toMatchObject({ installs: 1, activeLast7Days: 0 });
		expect(body.installs.map((install) => install.id).sort()).toEqual(["3f2a9c10", "aaaaaaaa"]);
	});
});

describe("scheduled cleanup", () => {
	it("removes only installs quiet for over 180 days", async () => {
		await checkIn({ installId: ID, version: "2.7.3", build: "271" });
		await checkIn({ installId: OTHER_ID, version: "2.7.3", build: "271" });
		await env.DB.prepare("UPDATE installs SET last_seen = ?1 WHERE install_id = ?2")
			.bind(Date.now() - 181 * DAY, ID)
			.run();

		await worker.scheduled({} as ScheduledController, env);

		expect(await row(ID)).toBeNull();
		expect(await row(OTHER_ID)).not.toBeNull();
	});
});
