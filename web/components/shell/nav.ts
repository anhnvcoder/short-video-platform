// Routes where Home is the current page: the two tabs of the feed. Part A has no other route behind the login.
const homePaths = new Set(["/", "/following"]);

export function isHomePath(pathname: string): boolean {
  return homePaths.has(pathname);
}
