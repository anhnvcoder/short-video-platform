import { Suspense, isValidElement, type ReactElement, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SidebarDesktop } from "@/components/shell/sidebar-desktop";
import type { MyProfile } from "@/server/me";

const profile = vi.hoisted(() => ({ load: vi.fn<() => Promise<MyProfile | null>>() }));

vi.mock("next-intl/server", () => ({
  getMessages: async () => ({ shell: { home: "Home" } }),
  getTranslations: async () => (key: string) => `common.${key}`,
}));
vi.mock("@/server/current-user", () => ({ requireSession: async () => ({ userId: "user-1" }) }));
vi.mock("@/server/me", () => ({ loadMyProfile: profile.load }));
vi.mock("@/components/shell/sidebar-desktop", () => ({ SidebarDesktop: () => null }));
vi.mock("@/components/shell/bottom-nav", () => ({ BottomNav: () => null }));

const { default: MainLayout } = await import("./layout");

type AnyElement = ReactElement<Record<string, unknown> & { children?: ReactNode }>;

function find(node: ReactNode, match: (element: AnyElement) => boolean): AnyElement | undefined {
  if (Array.isArray(node)) {
    for (const child of node as ReactNode[]) {
      const found = find(child, match);
      if (found) return found;
    }
    return undefined;
  }
  if (!isValidElement(node)) return undefined;
  const element = node as AnyElement;
  return match(element) ? element : find(element.props.children, match);
}

// Renders a server component element one level down (a plain or async function component), as React would.
async function renderComponent(element: AnyElement): Promise<ReactNode> {
  const component = element.type as (props: unknown) => ReactNode | Promise<ReactNode>;
  return component(element.props);
}

async function sidebarAccount(element: AnyElement): Promise<unknown> {
  const sidebar = find(await renderComponent(element), (e) => e.type === SidebarDesktop);
  if (!sidebar) throw new Error("no SidebarDesktop rendered");
  return sidebar.props.account;
}

function within<T>(run: Promise<T>, ms: number): Promise<T> {
  return Promise.race([
    run,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`layout waited more than ${ms} ms`)), ms)),
  ]);
}

describe("(main) layout", () => {
  beforeEach(() => {
    profile.load.mockReset();
  });

  it("returns without waiting for the profile and shows the avatar alone meanwhile", async () => {
    profile.load.mockReturnValue(new Promise<never>(() => {}));

    const tree = await within(MainLayout({ children: "page" }), 100);

    const suspense = find(tree, (e) => e.type === Suspense);
    if (!suspense) throw new Error("the side bar is not in a Suspense boundary");
    expect(await sidebarAccount(suspense.props.fallback as AnyElement)).toBeNull();
  });

  it("streams the name and handle into the side bar once GET /me answers", async () => {
    profile.load.mockResolvedValue({ userId: "user-1", displayName: "Minh Anh", handle: "minhanh" });

    const tree = await MainLayout({ children: "page" });
    const suspense = find(tree, (e) => e.type === Suspense);
    if (!suspense) throw new Error("the side bar is not in a Suspense boundary");
    const child = suspense.props.children as AnyElement;

    expect(await sidebarAccount((await renderComponent(child)) as AnyElement)).toEqual({
      displayName: "Minh Anh",
      handle: "minhanh",
    });
  });

  it("keeps the avatar alone when GET /me gives nothing", async () => {
    profile.load.mockResolvedValue(null);

    const tree = await MainLayout({ children: "page" });
    const child = find(tree, (e) => e.type === Suspense)?.props.children as AnyElement;

    expect(await sidebarAccount((await renderComponent(child)) as AnyElement)).toBeNull();
  });
});
