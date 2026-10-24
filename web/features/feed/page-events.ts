// Browser state the players follow, shared by the feed and the share page.

export function subscribeVisibility(onChange: () => void) {
  document.addEventListener("visibilitychange", onChange);
  return () => document.removeEventListener("visibilitychange", onChange);
}

// The window's load event waits for every eager image, the current poster among them: what waits for it starts after
// the page's largest paint instead of sharing a slow link with it.
export function subscribeLoad(onChange: () => void) {
  window.addEventListener("load", onChange);
  return () => window.removeEventListener("load", onChange);
}

// Keys typed into a field, or Space on a control that Space activates, are not player shortcuts.
export function ignoresShortcut(event: KeyboardEvent): boolean {
  const target = event.target instanceof HTMLElement ? event.target : null;
  if (!target) {
    return false;
  }
  if (target.isContentEditable || target.closest("input, textarea, select")) {
    return true;
  }
  return event.key === " " && target.closest("button, a, [role='tab']") !== null;
}
