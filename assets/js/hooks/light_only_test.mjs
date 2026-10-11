import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

test("the app has one light theme: no dark palette, variant or theme switching", () => {
	for (const path of ["../../css/app.css", "../../css/adaptive_home.css"]) {
		const css = read(path);
		assert.doesNotMatch(css, /data-theme/, path);
		assert.doesNotMatch(css, /prefers-color-scheme:\s*dark/, path);
		assert.doesNotMatch(css, /@custom-variant dark/, path);
	}

	assert.doesNotMatch(read("../app_bootstrap.js"), /theme/i);
});
