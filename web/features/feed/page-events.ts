// Browser state the players follow, shared by the feed and the share page.

export function subscribeVisibility(onChange: () => void) {
  document.addEventListener("visibilitychange", onChange);
  return () => document.removeEventListener("visibilitychange", onChange);
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
