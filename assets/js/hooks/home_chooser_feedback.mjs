const registeredTargets = new WeakSet();

export function registerHomeChooserFeedback(target = window, root = document) {
  if (registeredTargets.has(target)) return;
  registeredTargets.add(target);
  target.addEventListener("phx:home_chooser_rejected", () => {
    const alert = root.querySelector(
      '#home-page #home-alternatives-panel:not([hidden]):not([inert]) #home-chooser-error[role="alert"]',
    );
    if (!alert) return;
    alert.focus({ preventScroll: true });
    alert.scrollIntoView({ block: "nearest", behavior: "instant" });
  });
}
