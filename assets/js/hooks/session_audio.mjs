export class SessionAudio {
	constructor() {
		this.ctx = null;
		this.bus = null;
		this.scheduledOscs = [];
	}

	context() {
		if (!this.ctx) {
			const AudioContext = window.AudioContext || window.webkitAudioContext;
			this.ctx = new AudioContext();
		}
		return this.ctx;
	}

	currentTime() {
		return this.context().currentTime;
	}

	ensureRunning() {
		const ctx = this.context();
		if (ctx.state === "suspended") ctx.resume().catch(() => {});
	}

	masterBus() {
		const ctx = this.context();
		if (!this.bus) {
			this.bus = ctx.createGain();
			this.bus.gain.value = 1.0;
			this.bus.connect(ctx.destination);
		}
		return this.bus;
	}

	tickAt(startAt, { freq, durMs, gain, type = "sine", attackMs = 3 }) {
		const ctx = this.context();
		const dur = durMs / 1000;
		const osc = ctx.createOscillator();
		const g = ctx.createGain();
		osc.type = type;
		osc.frequency.setValueAtTime(freq, startAt);
		g.gain.setValueAtTime(0, startAt);
		g.gain.linearRampToValueAtTime(gain, startAt + attackMs / 1000);
		g.gain.exponentialRampToValueAtTime(0.0001, startAt + dur);
		osc.connect(g);
		g.connect(this.masterBus());
		osc.start(startAt);
		osc.stop(startAt + dur + 0.05);
		this.trackOsc(osc);
	}

	chimeAt(startAt, { freq, durMs = 300, gain = 0.4 }) {
		const ctx = this.context();
		const dur = durMs / 1000;
		const partials = [
			{ m: 1, g: 1.0, d: dur },
			{ m: 2, g: 0.4, d: dur * 0.7 },
			{ m: 3, g: 0.2, d: dur * 0.5 },
		];
		const master = ctx.createGain();
		master.gain.value = gain;
		master.connect(this.masterBus());
		partials.forEach((partial) => {
			const osc = ctx.createOscillator();
			const g = ctx.createGain();
			osc.frequency.setValueAtTime(freq * partial.m, startAt);
			g.gain.setValueAtTime(0, startAt);
			g.gain.linearRampToValueAtTime(partial.g, startAt + 0.005);
			g.gain.exponentialRampToValueAtTime(0.0001, startAt + partial.d);
			osc.connect(g);
			g.connect(master);
			osc.start(startAt);
			osc.stop(startAt + partial.d + 0.05);
			this.trackOsc(osc);
		});
	}

	playLeadBeep() {
		this.tickAt(this.currentTime() + 0.02, {
			freq: 440,
			durMs: 150,
			gain: 0.6,
			type: "triangle",
		});
	}

	playRepBeep() {
		const startAt = this.currentTime() + 0.02;
		this.tickAt(startAt, {
			freq: 800,
			durMs: 40,
			gain: 0.7,
			type: "square",
			attackMs: 2,
		});
		this.chimeAt(startAt, { freq: 659.25, durMs: 350, gain: 0.8 });
		this.tickAt(startAt, {
			freq: 329.63,
			durMs: 200,
			gain: 0.4,
			type: "triangle",
		});
	}

	playCompletionFanfare() {
		this.stop();
		const now = this.currentTime();
		this.chimeAt(now, { freq: 523.25, durMs: 250, gain: 0.4 });
		this.chimeAt(now + 0.2, { freq: 659.25, durMs: 300, gain: 0.4 });
		this.chimeAt(now + 0.4, { freq: 783.99, durMs: 350, gain: 0.5 });
		this.chimeAt(now + 0.6, { freq: 1046.5, durMs: 900, gain: 0.5 });
	}

	trackOsc(osc) {
		this.scheduledOscs.push(osc);
		osc.addEventListener("ended", () => {
			this.scheduledOscs = this.scheduledOscs.filter((item) => item !== osc);
		});
	}

	stop() {
		if (!this.ctx) return;
		const now = this.ctx.currentTime;
		this.scheduledOscs.forEach((osc) => {
			try {
				osc.stop(now);
			} catch (_) {}
		});
		this.scheduledOscs = [];
	}

	close() {
		if (this.ctx) this.ctx.close();
	}
}
