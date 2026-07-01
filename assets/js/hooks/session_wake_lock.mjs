export class SessionWakeLock {
	constructor() {
		this.lock = null;
		this.active = false;
	}

	async acquire() {
		this.active = true;
		if (this.lock || document.visibilityState !== "visible") return;

		try {
			const lock = await navigator.wakeLock?.request("screen");
			if (!lock) return;

			this.lock = lock;
			lock.addEventListener?.("release", () => {
				this.lock = null;
				if (this.active && document.visibilityState === "visible") {
					this.acquire();
				}
			});
		} catch (_error) {}
	}

	reacquireWhenVisible() {
		if (!this.active || document.visibilityState !== "visible") return;
		this.lock = null;
		this.acquire();
	}

	release() {
		this.active = false;
		this.lock?.release?.().catch(() => {});
		this.lock = null;
	}
}
