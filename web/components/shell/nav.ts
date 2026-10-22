// Which item of the navigation is the current page (web/design/BottomNav.dc.html, SidebarDesktop.dc.html). Profile is
// the user's own profile, /me; another user's profile at /u/<handle> marks nothing, as in the design (M35–M37).
export type NavItem = "home" | "upload" | "profile";

// Routes where Home is the current page: the two tabs of the feed.
const homePaths = new Set(["/", "/following"]);

export function currentNavItem(pathname: string): NavItem | null {
  if (homePaths.has(pathname)) {
    return "home";
  }
  if (pathname === "/upload") {
    return "upload";
  }
  if (pathname === "/me") {
    return "profile";
  }
  return null;
}
