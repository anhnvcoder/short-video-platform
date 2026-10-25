import { NextIntlClientProvider } from "next-intl";
import { Suspense, isValidElement, type ReactElement, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { SidebarAccount, SidebarDesktop } from "@/components/shell/sidebar-desktop";
import type { MyProfile } from "@/server/me";

const profile = vi.hoisted(() => ({ load: vi.fn<() => Promise<MyProfile | null>>() }));

vi.mock("next-intl/server", () => ({
  getMessages: async () => ({ common: { appName: "SVP", loading: "Loading…" }, shell: { home: "Home" } }),
  getTranslations: async () => (key: string) => `common.${key}`,
}));
vi.mock("@/server/current-user", () => ({ requireSession: async () => ({ userId: "user-1" }) }));
vi.mock("@/server/me", () => ({ loadMyProfile: profile.load }));
vi.mock("@/components/shell/sidebar-desktop", () => ({ SidebarDesktop: () => null, SidebarAccount: () => null }));
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

function findAll(node: ReactNode, match: (element: AnyElement) => boolean): AnyElement[] {
  if (Array.isArray(node)) return (node as ReactNode[]).flatMap((child) => findAll(child, match));
  if (!isValidElement(node)) return [];
  const element = node as AnyElement;
  return [...(match(element) ? [element] : []), ...findAll(element.props.children, match)];
}

// Renders a server component element one level down (a plain or async function component), as React would.
async function renderComponent(element: AnyElement): Promise<ReactNode> {
  const component = element.type as (props: unknown) => ReactNode | Promise<ReactNode>;
  return component(element.props);
}

// The account block the side bar gets: a Suspense boundary with the avatar alone as fallback.
function accountBoundary(tree: ReactNode): AnyElement {
  const sidebar = find(tree, (e) => e.type === SidebarDesktop);
  if (!sidebar) throw new Error("no SidebarDesktop rendered");
  const boundary = sidebar.props.account as AnyElement;
  if (!isValidElement(boundary) || boundary.type !== Suspense)
    throw new Error("the account is not in a Suspense boundary");
  return boundary;
}

// The `account` of the SidebarAccount that `element` is, or renders to.
async function shownAccount(element: AnyElement): Promise<unknown> {
  const block = element.type === SidebarAccount ? element : ((await renderComponent(element)) as AnyElement);
  if (block.type !== SidebarAccount) throw new Error("no SidebarAccount rendered");
  return block.props.account;
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

    expect(await shownAccount(accountBoundary(tree).props.fallback as AnyElement)).toBeNull();
  });

  it("streams the name and handle into the side bar once GET /me answers", async () => {
    profile.load.mockResolvedValue({ userId: "user-1", displayName: "Minh Anh", handle: "minhanh" });

    const tree = await MainLayout({ children: "page" });

    expect(await shownAccount(accountBoundary(tree).props.children as AnyElement)).toEqual({
      displayName: "Minh Anh",
      handle: "minhanh",
    });
  });

  it("keeps the avatar alone when GET /me gives nothing", async () => {
    profile.load.mockResolvedValue(null);

    const tree = await MainLayout({ children: "page" });

    expect(await shownAccount(accountBoundary(tree).props.children as AnyElement)).toBeNull();
  });

  it("waits for the name in the account block only: the side bar, log out included, is never replaced", async () => {
    profile.load.mockReturnValue(new Promise<never>(() => {}));

    const tree = await MainLayout({ children: "page" });

    // No boundary around the side bar itself: a boundary's content replaces its fallback's elements when it arrives,
    // and a click on the fallback's log out under way at that moment was lost.
    expect(find(tree, (e) => e.type === Suspense)).toBeUndefined();
    expect(find(tree, (e) => e.type === SidebarDesktop)).toBeTruthy();
  });

  it("gives both bars the shell's messages and the label of their links' spinner, nothing else", async () => {
    profile.load.mockResolvedValue(null);

    const tree = await MainLayout({ children: "page" });

    // A nested provider replaces the root's messages: what is not here, Home's spinner cannot translate.
    const providers = findAll(tree, (e) => e.type === NextIntlClientProvider);
    expect(providers).toHaveLength(2);
    for (const provider of providers) {
      expect(provider.props.messages).toEqual({ shell: { home: "Home" }, common: { loading: "Loading…" } });
    }
  });
});
