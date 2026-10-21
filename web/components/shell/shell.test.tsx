import { act, fireEvent, render, renderHook, screen, within } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { usePathname } from "next/navigation";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import { BottomNav } from "./bottom-nav";
import { ErrorsIntlProvider, useBrowserLocale } from "./errors-intl";
import { RouteError, rateLimitWait } from "./route-error";
import { SidebarDesktop } from "./sidebar-desktop";
import { useCountdown } from "./use-countdown";

vi.mock("next/navigation", () => ({ usePathname: vi.fn(() => "/") }));

const userId = "0192f0c1-7a3e-7c4b-9d2e-5f6a7b8c9d0e";

// Real messages, with the namespace the main layout passes down: a missing key fails here.
function renderShell(locale: Locale, pathname = "/") {
  vi.mocked(usePathname).mockReturnValue(pathname);
  return render(
    <NextIntlClientProvider locale={locale} messages={{ shell: messagesFor(locale).shell }}>
      <SidebarDesktop userId={userId} appName="SVP" />
      <BottomNav />
    </NextIntlClientProvider>,
  );
}

afterEach(() => {
  vi.useRealTimers();
});

describe("navigation of part A", () => {
  it.each<Locale>(["vi", "en"])("%s: both bars link Home only, no Upload or Profile", (locale) => {
    renderShell(locale);
    const shell = messagesFor(locale).shell;
    const navs = screen.getAllByRole("navigation", { name: shell.navLabel });
    expect(navs).toHaveLength(2);
    for (const nav of navs) {
      const links = within(nav).getAllByRole("link");
      expect(links.map((link) => [link.textContent, link.getAttribute("href")])).toEqual([[shell.home, "/"]]);
    }
    expect(screen.queryByText(/Tải lên|Upload|Hồ sơ|Profile/)).toBeNull();
  });

  it.each(["/", "/following"])("marks Home as the current page on %s", (pathname) => {
    renderShell("vi", pathname);
    for (const link of screen.getAllByRole("link", { name: "Trang chủ" })) {
      expect(link.getAttribute("aria-current")).toBe("page");
    }
  });

  it("marks nothing current on another page", () => {
    renderShell("vi", "/somewhere");
    for (const link of screen.getAllByRole("link", { name: "Trang chủ" })) {
      expect(link.hasAttribute("aria-current")).toBe(false);
    }
  });

  it.each<Locale>(["vi", "en"])("%s: log out is a POST form to /logout in both bars, never a link", (locale) => {
    renderShell(locale);
    const label = messagesFor(locale).shell.logout;
    const buttons = screen.getAllByRole("button", { name: label });
    expect(buttons).toHaveLength(2);
    for (const button of buttons) {
      expect(button.getAttribute("type")).toBe("submit");
      const form = button.closest("form");
      expect(form?.getAttribute("method")).toBe("post");
      expect(form?.getAttribute("action")).toBe("/logout");
    }
    expect(screen.queryByRole("link", { name: label })).toBeNull();
  });

  it("lists the feed shortcuts on Home only", () => {
    renderShell("en");
    expect(screen.getByRole("heading", { name: "Keyboard shortcuts" })).toBeTruthy();
    expect(screen.getByText("Mute / unmute")).toBeTruthy();
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
