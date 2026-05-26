export class SessionWakeLock {
	constructor() {
		this.lock = null;
	}

	acquire() {
		if (this.lock) return;
		navigator.wakeLock
			?.request("screen")
			.then((lock) => {
				this.lock = lock;
			})
			.catch(() => {});
	}

	reacquireWhenVisible() {
		if (document.visibilityState !== "visible") return;
		this.lock = null;
		this.acquire();
	}

	release() {
		this.lock?.release?.().catch(() => {});
		this.lock = null;
	}
}
