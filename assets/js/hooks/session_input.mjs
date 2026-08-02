export function isPauseToggleKey(event) {
	return event.key === "Enter" || event.key === " " || event.code === "Space";
}
