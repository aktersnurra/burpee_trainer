// Drives Home's swipes and the studio (Edit and New) in a phone-sized browser against the server
// scripts/e2e/studio_preview.exs started, and fails (exit 1) when something is off. See
// docs/guides/studio-e2e.md.
//
//   PREVIEW_DIR=$DIR node scripts/e2e/studio_journey.mjs
//
// Needs Playwright with Chromium (`npm i -D playwright` anywhere on the module path, or NODE_PATH).
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const dir = process.env.PREVIEW_DIR;
if (!dir) throw new Error("set PREVIEW_DIR to the directory studio_preview.exs wrote preview.json to");
const info = JSON.parse(fs.readFileSync(`${dir}/preview.json`, "utf8"));
const BASE = process.env.BASE_URL ?? `http://localhost:${process.env.PORT ?? info.port}`;
const shots = process.env.SHOTS_DIR;
if (shots) fs.mkdirSync(shots, { recursive: true });

const failures = [];
const check = (ok, what, detail = "") => {
	console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : ` ${detail}`}`);
	if (!ok) failures.push(what);
};

async function swipe(client, [x1, y1], [x2, y2], steps = 8, ms = 220) {
	await client.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x1, y: y1 }] });
	for (let i = 1; i <= steps; i++) {
		await client.send("Input.dispatchTouchEvent", {
			type: "touchMove",
			touchPoints: [{ x: x1 + ((x2 - x1) * i) / steps, y: y1 + ((y2 - y1) * i) / steps }],
		});
		await new Promise((r) => setTimeout(r, ms / steps));
	}
	await client.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
}

// A finger held on an element for `ms`, then lifted.
async function hold(client, selector, ms) {
	const b = await page.locator(selector).boundingBox();
	const point = { x: b.x + b.width / 2, y: b.y + b.height / 2 };
	await client.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [point] });
	await new Promise((r) => setTimeout(r, ms));
	await client.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
}

const browser = await chromium.launch();
const context = await browser.newContext({
	viewport: { width: 390, height: 844 },
	deviceScaleFactor: 2,
	isMobile: true,
	hasTouch: true,
});
await context.addCookies([
	{ name: "_burpee_trainer_key", value: info.cookie, domain: new URL(BASE).hostname, path: "/", httpOnly: true, secure: true, sameSite: "Lax" },
]);
const page = await context.newPage();
const client = await context.newCDPSession(page);
const problems = [];
page.on("console", (m) => m.type() === "error" && problems.push(m.text()));
page.on("pageerror", (e) => problems.push(e.message));
const shot = (name) => shots && page.screenshot({ path: `${shots}/${name}.png` });
const settle = (ms = 500) => page.waitForTimeout(ms);

// The geometry every screen must share: the left edge, no sideways scroll, targets you can hit.
async function geometry() {
	return page.evaluate(() => {
		const visible = (e) => e.offsetParent !== null || getComputedStyle(e).position === "fixed";
		const left = (sel) => {
			const e = document.querySelector(sel);
			return e && visible(e) ? Math.round(e.getBoundingClientRect().left) : null;
		};
		const small = [...document.querySelectorAll("button, a[href], [role=spinbutton], .studio-segment-option, .studio-number-field")]
			.filter(visible)
			.filter((e) => !e.matches(".studio-part"))
			.map((e) => ({ e, r: e.getBoundingClientRect() }))
			.filter(({ r }) => r.width > 0 && r.height > 0 && (Math.min(r.width, r.height) < 40 || Math.max(r.width, r.height) < 44))
			.map(({ e, r }) => `${e.id || e.getAttribute("aria-label") || e.textContent.trim().slice(0, 20)} ${Math.round(r.width)}x${Math.round(r.height)}`);
		return {
			overflow: document.documentElement.scrollWidth > window.innerWidth,
			dock: left(".chat-dock .composer"),
			back: left("#studio-back, #home-request-abort"),
			summary: left("#home-summary"),
			small,
		};
	});
}

await page.goto(`${BASE}/`);
await page.waitForSelector("#home-summary");
await settle(800);
const home = await geometry();
check(!home.overflow, "Home does not scroll sideways");
check(home.small.length === 0, "Home's buttons are big enough to hit", home.small.join(", "));
// Swap, Edit and New a tap each, along the bottom edge within the thumb's reach.
const corner = await page.locator("#home-corner-new").boundingBox();
check(corner && corner.y + corner.height > 844 - 80, "Swap, Edit and New sit along the bottom edge", JSON.stringify(corner));
await shot("01-home");

// Swipe right: the swap drawer; left: back.
await swipe(client, [60, 400], [320, 410]);
await settle(700);
check(await page.evaluate(() => !document.querySelector("#home-alternatives-panel").hidden), "swipe right opens the swap drawer");
await shot("02-drawer");
await swipe(client, [300, 400], [60, 405]);
await settle(600);
check(await page.evaluate(() => document.querySelector("#home-alternatives-panel").hidden), "swipe left closes it");

// Edit.
await page.tap("#home-corner-edit");
await page.waitForSelector("#home-studio");
await settle(600);
let g = await geometry();
check(g.back === home.summary || Math.abs(g.back - 30) <= 1, "the studio starts where Home does", `back=${g.back} home=${home.summary}`);
check(Math.abs(g.dock - 30) <= 1, "the docked box starts at the same edge", `dock=${g.dock}`);
check(!g.overflow, "the studio does not scroll sideways");
check(g.small.length === 0, "the studio's buttons are big enough to hit", g.small.join(", "));
await shot("04-edit");
await page.fill("#home-edit-instruction", "Make it 150 reps");
await page.tap("#home-edit-send");
await settle(400);
check(await page.isVisible("#home-update-loading"), "a spinner shows while the coach works");
await page.waitForSelector("#home-request-run", { timeout: 20000 });
check(!(await page.isVisible("#home-request-save")), "Run alone sits under the proposal");
g = await geometry();
check(g.small.length === 0, "the proposal's buttons are big enough to hit", g.small.join(", "));
await shot("05-proposal");
await page.tap("#home-request-abort");
await page.waitForSelector("#home-summary");

// New.
await page.tap("#home-corner-new");
await page.waitForSelector("#studio-new-form");
check(await page.isVisible("#studio-create"), "New opens on one form with Create");
check(!(await page.isVisible("#studio-pace")), "style, set size and pace start folded under More");
await page.tap("label:has(#studio-burpee_type-six_count)");
await page.tap("#studio-more");
await settle(300);
check(await page.isVisible("#studio-pace"), "More unfolds them");
await page.tap("label:has(#studio-pacing_style-unbroken)");
await page.waitForSelector("#studio-sets");
check(await page.isVisible("#studio-sets"), "unbroken asks for a set size");
const before = Number(await page.inputValue("#studio-duration"));
await page.tap(before > 5 ? "#studio-duration-down" : "#studio-duration-up");
await settle(400);
const after = Number(await page.inputValue("#studio-duration"));
check(Math.abs(after - before) === 5, "a value's buttons move it by a step", `${before} -> ${after}`);
const held = Number(await page.inputValue("#studio-reps"));
await hold(client, "#studio-reps-down", 1100);
await settle(600);
const released = Number(await page.inputValue("#studio-reps"));
check(held - released >= 15, "a held button keeps stepping", `${held} -> ${released}`);
check(await page.isVisible("#studio-pace"), "More stays open while the values change");
await page.fill("#studio-reps", "30");
await page.tap("#studio-note");
await settle(800);
check((await page.inputValue("#studio-reps")) === "30", "a value can be typed");
check((await page.textContent("#studio-reps-hint")).includes("moving"), "the form says what the values come to");
g = await geometry();
check(!g.overflow, "the form does not scroll sideways");
check(g.small.length === 0, "the form's controls are big enough to hit", g.small.join(", "));
await shot("06-form");
await page.tap("#studio-create");
await page.waitForSelector("#home-request-run", { timeout: 20000 });
check(await page.isVisible("#studio-suggestions .studio-suggestion"), "the coach offers its guesses at the next ask");
g = await geometry();
check(!g.overflow, "the proposal does not scroll sideways");
check(g.small.length === 0, "the suggested asks are big enough to hit", g.small.join(", "));
await shot("07-new-proposal");
await page.tap("#home-request-run");
await page.waitForURL(/\/session\//, { timeout: 20000 });
check(true, "Run starts the workout");

check(problems.length === 0, "the browser logged no errors", problems.join(" | "));
await browser.close();
if (failures.length) {
	console.error(`\n${failures.length} check(s) failed`);
	process.exit(1);
}
console.log("\nall checks passed");
