// A message that is already half written opens with the cursor at its end, on the line left
// for more: New's chat starts on "Additional request: ".
export function caretToEnd(el) {
	el.focus();
	const end = el.value.length;
	el.setSelectionRange(end, end);
	// A long message would otherwise open scrolled to its top, with the cursor out of sight.
	el.scrollTop = el.scrollHeight;
}

export default {
	mounted() {
		if (this.el.dataset.caret === "end") caretToEnd(this.el);
	},
};
