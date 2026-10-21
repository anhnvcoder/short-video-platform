import { beforeEach, describe, expect, it, vi } from "vitest";
import { AuthForm } from "@/components/auth/auth-form";
import { loginAction, registerAction } from "@/server/auth-actions";
import { getCurrentUser } from "@/server/current-user";
import { AuthPage } from "./auth-page";
import LoginPage, { generateMetadata as loginMetadata } from "./login/page";
import RegisterPage from "./register/page";

vi.mock("@/server/current-user", () => ({ getCurrentUser: vi.fn() }));
vi.mock("@/server/auth-actions", () => ({ loginAction: vi.fn(), registerAction: vi.fn() }));
vi.mock("next-intl/server", () => ({ getTranslations: async () => (key: string) => `auth.${key}` }));
vi.mock("next/navigation", () => ({
  redirect: vi.fn((url: string) => {
    throw new Error(`redirect ${url}`);
  }),
}));

const params = (query: Record<string, string | string[]>) => Promise.resolve(query);

beforeEach(() => {
  vi.mocked(getCurrentUser).mockResolvedValue(null);
});

describe("login and register pages", () => {
  it("sends a visitor who is already logged in to the home page, whatever next says", async () => {
    vi.mocked(getCurrentUser).mockResolvedValue({ userId: "u1" });
    await expect(
      AuthPage({ mode: "login", action: loginAction, searchParams: params({ next: "/following" }) }),
    ).rejects.toThrow("redirect /");
  });

  it("renders the form with its action and passes next on unchecked", async () => {
    const element = await AuthPage({
      mode: "register",
      action: registerAction,
      searchParams: params({ next: "//evil.example" }),
    });
    expect(element.type).toBe(AuthForm);
    // The action checks next (WEB-4); the page only fills the hidden field and never redirects to it.
    expect(element.props).toEqual({ mode: "register", action: registerAction, next: "//evil.example" });
  });

  it("renders the form when the session cannot be read (Redis down), not the error page", async () => {
    vi.mocked(getCurrentUser).mockRejectedValue(new Error("connect ECONNREFUSED 127.0.0.1:6379"));
    const element = await AuthPage({
      mode: "login",
      action: loginAction,
      searchParams: params({ next: "/following" }),
    });
    expect(element.type).toBe(AuthForm);
    expect(element.props).toEqual({ mode: "login", action: loginAction, next: "/following" });
  });

  it("ignores a repeated next query and a missing one", async () => {
    const repeated = await AuthPage({
      mode: "login",
      action: loginAction,
      searchParams: params({ next: ["/a", "/b"] }),
    });
    expect(repeated.props.next).toBeUndefined();
    const missing = await AuthPage({ mode: "login", action: loginAction, searchParams: params({}) });
    expect(missing.props.next).toBeUndefined();
  });

  it("wires each route to its own action", () => {
    const searchParams = params({});
    expect(LoginPage({ searchParams }).props).toMatchObject({ mode: "login", action: loginAction });
    expect(RegisterPage({ searchParams }).props).toMatchObject({ mode: "register", action: registerAction });
  });

  it("titles the page", async () => {
    expect(await loginMetadata()).toEqual({ title: "auth.login.metaTitle" });
  });
});
