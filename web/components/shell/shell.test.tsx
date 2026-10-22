import { act, fireEvent, render, renderHook, screen, within } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { usePathname } from "next/navigation";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import { BottomNav } from "./bottom-nav";
import { ErrorsIntlProvider, useBrowserLocale } from "./errors-intl";
import { RouteError, rateLimitWait } from "./route-error";
import { SidebarDesktop, type ShellAccount } from "./sidebar-desktop";
import { useCountdown } from "./use-countdown";

vi.mock("next/navigation", () => ({ usePathname: vi.fn(() => "/") }));

const userId = "0192f0c1-7a3e-7c4b-9d2e-5f6a7b8c9d0e";

const account = { displayName: "Lan Phương", handle: "lanphuong" };

// Real messages, with the namespace the main layout passes down: a missing key fails here.
function renderShell(locale: Locale, pathname = "/", shellAccount: ShellAccount | null = account) {
  vi.mocked(usePathname).mockReturnValue(pathname);
  return render(
    <NextIntlClientProvider locale={locale} messages={{ shell: messagesFor(locale).shell }}>
      <SidebarDesktop userId={userId} account={shellAccount} appName="SVP" />
      <BottomNav />
    </NextIntlClientProvider>,
  );
}

function sidebar(): HTMLElement {
  return screen.getByRole("complementary");
}

function bottomBar(): HTMLElement {
  const nav = screen.getAllByRole("navigation").find((element) => !sidebar().contains(element));
  if (!nav) {
    throw new Error("no bottom bar");
  }
  return nav;
}

// [text, href] of every link of `container`, in order.
function links(container: HTMLElement): (string | null)[][] {
  return within(container)
    .getAllByRole("link")
    .map((link) => [link.textContent, link.getAttribute("href")]);
}

function currentLinks(): (string | null)[] {
  return screen
    .getAllByRole("link")
    .filter((link) => link.getAttribute("aria-current") === "page")
    .map((link) => link.getAttribute("href"));
}

describe("navigation", () => {
  it.each<Locale>(["vi", "en"])(
    "%s: Home, Profile and Upload in the side bar; Home, Upload, Profile below",
    (locale) => {
      renderShell(locale);
      const shell = messagesFor(locale).shell;
      expect(screen.getAllByRole("navigation", { name: shell.navLabel })).toHaveLength(2);
      expect(links(sidebar())).toEqual([
        ["SVP", "/"],
        [shell.home, "/"],
        [shell.profile, "/me"],
        [shell.upload, "/upload"],
      ]);
      expect(links(bottomBar())).toEqual([
        [shell.home, "/"],
        [shell.upload, "/upload"],
        [shell.profile, "/me"],
      ]);
    },
  );

  it.each([
    ["/", ["/", "/"]],
    ["/following", ["/", "/"]],
    ["/upload", ["/upload", "/upload"]],
    ["/me", ["/me", "/me"]],
    // Another user's profile is not the Profile item, which is the user's own (M35–M37).
    ["/u/minhanh", []],
    ["/v/01928c6e-7b3a-7cde-8f01-000000000001", []],
    ["/me/videos", []],
    ["/uploads", []],
    ["/somewhere", []],
  ])("on %s marks %j as the current page in both bars", (pathname, expected) => {
    renderShell("vi", pathname);
    expect(currentLinks()).toEqual(expected);
  });

  it("shows the account's name and handle beside its avatar", () => {
    renderShell("vi");
    const block = within(sidebar()).getByText("Lan Phương").parentElement!;
    expect(within(block).getByText("@lanphuong")).toBeTruthy();
    // The avatar shows the name's first letter.
    expect(block.parentElement!.querySelector('span.rounded-full[aria-hidden="true"]')?.textContent).toBe("L");
    expect(screen.queryByText(messagesFor("vi").shell.account)).toBeNull();
  });

  it.each<Locale>(["vi", "en"])("%s: without a profile the account block shows the avatar and a label", (locale) => {
    renderShell(locale, "/", null);
    expect(within(sidebar()).getByText(messagesFor(locale).shell.account)).toBeTruthy();
    expect(sidebar().textContent).not.toContain("@");
  });

  it("renders a name with markup as text", () => {
    renderShell("vi", "/", { displayName: "<img src=x onerror=alert(1)>", handle: "lanphuong" });
    expect(within(sidebar()).getByText("<img src=x onerror=alert(1)>")).toBeTruthy();
    expect(sidebar().querySelector("img")).toBeNull();
  });

  it.each<Locale>(["vi", "en"])("%s: log out is a POST form to /logout in the side bar, never a link", (locale) => {
    renderShell(locale);
    const label = messagesFor(locale).shell.logout;
    const buttons = screen.getAllByRole("button", { name: label });
    // The bottom bar has none: log out is on the profile page there, as in the design.
    expect(buttons).toHaveLength(1);
    expect(sidebar().contains(buttons[0]!)).toBe(true);
    expect(buttons[0]!.getAttribute("type")).toBe("submit");
    const form = buttons[0]!.closest("form");
    expect(form?.getAttribute("method")).toBe("post");
    expect(form?.getAttribute("action")).toBe("/logout");
    expect(screen.queryByRole("link", { name: label })).toBeNull();
  });

  it("lists the feed shortcuts on Home only", () => {
    renderShell("en");
    expect(screen.getByRole("heading", { name: "Keyboard shortcuts" })).toBeTruthy();
    expect(screen.getByText("Mute / unmute")).toBeTruthy();
  });

  it.each(["/upload", "/me"])("lists no shortcuts on %s", (pathname) => {
    renderShell("en", pathname);
    expect(screen.queryByRole("heading", { name: "Keyboard shortcuts" })).toBeNull();
  });
});

function renderError(locale: Locale, error: unknown, retry = vi.fn()) {
  render(
    <ErrorsIntlProvider locale={locale}>
      <RouteError error={error} retry={retry} />
    </ErrorsIntlProvider>,
  );
  return retry;
}

function serverError(digest: string): Error {
  return Object.assign(new Error("connect ECONNREFUSED 10.0.0.5:6379 password=hunter2"), { digest });
}

describe("RouteError", () => {
  it.each<Locale>(["vi", "en"])("%s: shows translated text and the digest, never the message", (locale) => {
    const errors = messagesFor(locale).errors;
    const retry = renderError(locale, serverError("2481964823"));
    expect(screen.getByRole("heading", { level: 1, name: errors.generic.title })).toBeTruthy();
    expect(screen.getByText(errors.errorCode.replace("{digest}", "2481964823"))).toBeTruthy();
    expect(document.body.textContent).not.toContain("ECONNREFUSED");
    expect(document.body.textContent).not.toContain("hunter2");
    fireEvent.click(screen.getByRole("button", { name: errors.generic.retry }));
    expect(retry).toHaveBeenCalledOnce();
    expect(screen.getByRole("link", { name: errors.home }).getAttribute("href")).toBe("/");
  });

  it("handles a thrown value that is not an Error", () => {
    renderError("vi", "boom");
    expect(screen.getByRole("heading", { name: "Đã có lỗi xảy ra" })).toBeTruthy();
    expect(screen.queryByText(/Mã lỗi/)).toBeNull();
    expect(document.body.textContent).not.toContain("boom");
  });

  it.each<Locale>(["vi", "en"])("%s: a rate limit shows 429 with a countdown before retry", async (locale) => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const errors = messagesFor(locale).errors;
    const retry = renderError(locale, serverError("SVP_RATE_LIMITED;2"));
    expect(screen.getByText("429")).toBeTruthy();
    expect(screen.getByRole("heading", { name: errors.rateLimited.title })).toBeTruthy();
    const first = locale === "vi" ? "Thử lại sau 2 giây" : "Try again in 2 seconds";
    expect((screen.getByRole("button", { name: first }) as HTMLButtonElement).disabled).toBe(true);
    await act(async () => vi.advanceTimersByTime(1000));
    await act(async () => vi.advanceTimersByTime(1000));
    const button = screen.getByRole("button", { name: errors.rateLimited.retry });
    expect((button as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(button);
    expect(retry).toHaveBeenCalledOnce();
  });

  it("reads the wait only from a well-formed rate limit digest", () => {
    expect(rateLimitWait(serverError("SVP_RATE_LIMITED;30"))).toBe(30);
    expect(rateLimitWait(serverError("SVP_RATE_LIMITED;x"))).toBeNull();
    expect(rateLimitWait(serverError("SVP_RATE_LIMITED;-1"))).toBeNull();
    expect(rateLimitWait(serverError("123"))).toBeNull();
    expect(rateLimitWait(new Error("SVP_RATE_LIMITED;30"))).toBeNull();
    expect(rateLimitWait(null)).toBeNull();
  });
});

describe("useCountdown", () => {
  it("counts down once a second to 0 and restarts on a new key", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const first = {};
    const { result, rerender } = renderHook(({ seconds, key }) => useCountdown(seconds, key), {
      initialProps: { seconds: 2 as number | null, key: first as unknown },
    });
    expect(result.current).toBe(2);
    await act(async () => vi.advanceTimersByTime(1000));
    expect(result.current).toBe(1);
    await act(async () => vi.advanceTimersByTime(1000));
    expect(result.current).toBe(0);
    await act(async () => vi.advanceTimersByTime(5000));
    expect(result.current).toBe(0);
    rerender({ seconds: 2, key: {} });
    expect(result.current).toBe(2);
    rerender({ seconds: null, key: {} });
    expect(result.current).toBe(0);
  });

  // A phone pauses the timers of a page in the background; the callback then comes late, once.
  it("reads the time left from the clock when a callback comes late", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { result } = renderHook(() => useCountdown(7, "wait"));
    expect(result.current).toBe(7);
    // 3 s pass with no callback, then the pending one fires a second later: 4 s gone, 3 left.
    vi.setSystemTime(Date.now() + 3000);
    await act(async () => vi.advanceTimersByTime(1000));
    expect(result.current).toBe(3);
    // 10 s gone in all, past the 7 s wait: the first late callback ends it.
    vi.setSystemTime(Date.now() + 5000);
    await act(async () => vi.advanceTimersByTime(1000));
    expect(result.current).toBe(0);
  });

  it("follows the clock between whole seconds", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { result } = renderHook(() => useCountdown(3, "wait"));
    // A callback 1.5 s late leaves 0.5 s of the wait: shown as 1, then 0 half a second later.
    vi.setSystemTime(Date.now() + 1500);
    await act(async () => vi.advanceTimersByTime(1000));
    expect(result.current).toBe(1);
    await act(async () => vi.advanceTimersByTime(499));
    expect(result.current).toBe(1);
    await act(async () => vi.advanceTimersByTime(1));
    expect(result.current).toBe(0);
  });

  it("reads the clock again when the page becomes visible, before any callback", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { result } = renderHook(() => useCountdown(7, "wait"));
    vi.setSystemTime(Date.now() + 5000);
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(result.current).toBe(2);
    vi.setSystemTime(Date.now() + 5000);
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(result.current).toBe(0);
  });

  it("stops listening once the wait is replaced", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { result, rerender } = renderHook(({ seconds, key }) => useCountdown(seconds, key), {
      initialProps: { seconds: 7 as number | null, key: "first" as unknown },
    });
    rerender({ seconds: null, key: "second" });
    vi.setSystemTime(Date.now() + 3000);
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
      vi.advanceTimersByTime(5000);
    });
    expect(result.current).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe("useBrowserLocale", () => {
  afterEach(() => {
    document.cookie = "svp_locale=; max-age=0";
  });

  it("takes the svp_locale cookie first, then the browser languages", () => {
    document.cookie = "svp_locale=vi";
    expect(renderHook(() => useBrowserLocale()).result.current).toBe("vi");
    document.cookie = "svp_locale=fr";
    // jsdom's navigator.languages is en-US, en.
    expect(renderHook(() => useBrowserLocale()).result.current).toBe("en");
  });
});
