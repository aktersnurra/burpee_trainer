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
		const small = [...document.querySelectorAll("button, a[href], [role=spinbutton]")]
			.filter(visible)
			.filter((e) => !e.matches(".studio-part, .home-grab, .studio-dot"))
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
check(!(await page.$("#home-grab")), "closed, Home offers no Edit, Swap or New of its own");
await shot("01-home");

// Swipe right: the swap drawer; left: back.
await swipe(client, [60, 400], [320, 410]);
await settle(700);
check(await page.evaluate(() => !document.querySelector("#home-alternatives-panel").hidden), "swipe right opens the swap drawer");
await shot("02-drawer");
await swipe(client, [300, 400], [60, 405]);
await settle(600);
check(await page.evaluate(() => document.querySelector("#home-alternatives-panel").hidden), "swipe left closes it");

// Swipe up does nothing until the workout is opened; opened, it offers Edit / New; down: back.
await swipe(client, [200, 640], [205, 340]);
await settle(500);
check(!(await page.$("#home-options-sheet")), "swipe up on the closed workout does nothing");
await page.tap("#home-summary");
await page.waitForSelector("#home-grab");
await settle(500);
await swipe(client, [200, 640], [205, 340]);
await settle(600);
check(await page.isVisible("#home-options-sheet"), "swipe up on the opened workout opens Edit / New");
await shot("03-options");
await swipe(client, [200, 500], [205, 800]);
await settle(500);
check(!(await page.$("#home-options-sheet")), "swipe down closes it");

// Edit.
await page.tap("#home-grab");
await page.waitForSelector("#home-options-edit");
await page.tap("#home-options-edit");
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
check(await page.isVisible("#home-request-save"), "Save and Run sit under the proposal");
g = await geometry();
check(g.small.length === 0, "the proposal's buttons are big enough to hit", g.small.join(", "));
await shot("05-proposal");
await page.tap("#home-request-abort");
await page.waitForSelector("#home-summary");

// New.
if (!(await page.$("#home-grab"))) await page.tap("#home-summary");
await page.waitForSelector("#home-grab");
await page.tap("#home-grab");
await page.tap("#home-options-new");
await page.waitForSelector("#studio-step");
check((await page.textContent("#studio-question")).includes("Which burpee"), "New begins with its first question");
await page.tap("#home-pill-burpee_type-six_count");
await page.tap("#home-pill-pacing_style-unbroken");
await page.waitForSelector("#studio-step-duration");
const box = await (await page.$("#studio-step-duration")).boundingBox();
const y = box.y + box.height / 2;
const before = (await page.textContent("#studio-duration-value")).trim();
await swipe(client, [box.x + 80, y], [box.x + 260, y + 4]);
await settle(400);
const after = (await page.textContent("#studio-duration-value")).trim();
check(Number(after) === Number(before) + 5, "swiping a value right raises it by a step", `${before} -> ${after}`);
await page.tap("#studio-next");
await page.waitForSelector("#studio-reps-value");
check((await page.textContent(".studio-step-hint")).includes("moving"), "reps says what they come to");
await page.tap("#studio-next");
await page.waitForSelector("#studio-sets-value");
await page.tap("#studio-sets-down");
await settle(400);
check(/\d/.test(await page.textContent("#studio-sets-value")), "unbroken asks for a set size");
await page.tap("#studio-next");
await page.tap("#studio-next");
await page.waitForSelector("#studio-create");
check(await page.isVisible("#studio-add-request"), "the last screen offers Create workout or Add a request");
g = await geometry();
check(g.small.length === 0, "the summary's buttons are big enough to hit", g.small.join(", "));
await shot("06-summary");
await page.tap("#studio-create");
await page.waitForSelector("#home-request-run", { timeout: 20000 });
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
