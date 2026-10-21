// Joins class names, skipping the false, null and undefined of conditional classes.
export function cn(...classes: (string | false | null | undefined)[]): string {
  return classes.filter(Boolean).join(" ");
}
