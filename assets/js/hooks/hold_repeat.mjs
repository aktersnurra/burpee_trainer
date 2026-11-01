// A −/+ pair that keeps stepping while held: a press is one step (the button's own click), and a
// hold past HOLD_DELAY_MS repeats it every REPEAT_MS until the press ends or the button is
// disabled. The click that ends a hold is swallowed, so it adds no step of its own.
export const HOLD_DELAY_MS = 400;
export const REPEAT_MS = 110;

export function createHoldRepeat({ el, win, onStep }) {
	let timer = null;
	let held = false;

	const stop = () => {
		win.clearTimeout(timer);
		win.clearInterval(timer);
		timer = null;
	};

	const step = (button) => {
		if (button.disabled) return stop();
		held = true;
		onStep(button.getAttribute("phx-value-field"), button.getAttribute("phx-value-dir"));
	};

	const press = (e) => {
		const button = e.target.closest?.("button[phx-value-dir]");
		if (!button || button.disabled || e.button > 0) return;
		stop();
		held = false;
		timer = win.setTimeout(() => {
			step(button);
			if (timer !== null) timer = win.setInterval(() => step(button), REPEAT_MS);
		}, HOLD_DELAY_MS);
	};

	const click = (e) => {
		if (!held) return;
		held = false;
		e.stopPropagation();
		e.preventDefault();
	};

	const listeners = [
		[el, "pointerdown", press],
		[el, "pointerleave", stop],
		[el, "click", click],
		[win, "pointerup", stop],
		[win, "pointercancel", stop],
	];

	return {
		mount: () => listeners.forEach(([target, type, fn]) => target.addEventListener(type, fn)),
		destroy: () => {
			stop();
			listeners.forEach(([target, type, fn]) => target.removeEventListener(type, fn));
		},
	};
}

export default {
	mounted() {
		this.repeat = createHoldRepeat({
			el: this.el,
			win: window,
			onStep: (field, dir) => this.pushEvent("step_workout_value", { field, dir }),
		});
		this.repeat.mount();
	},
	destroyed() {
		this.repeat.destroy();
	},
};
