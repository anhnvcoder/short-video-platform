import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import type { AuthFormErrorCode, AuthState } from "@/server/auth-state";
import { AuthForm, type AuthMode } from "./auth-form";

type Action = (previous: AuthState, form: FormData) => Promise<AuthState>;

// Real messages of the locale, with the namespace the auth layout passes down: a missing key fails here.
function renderForm({
  locale = "vi",
  mode = "login",
  action = vi.fn<Action>(),
  next,
}: { locale?: Locale; mode?: AuthMode; action?: Action; next?: string } = {}) {
  render(
    <NextIntlClientProvider locale={locale} messages={{ auth: messagesFor(locale).auth }}>
      <AuthForm mode={mode} action={action} next={next} />
    </NextIntlClientProvider>,
  );
  return action;
}

function state(overrides: Partial<AuthState>): AuthState {
  return { email: "", handle: "", fieldErrors: {}, formError: null, retryAfterSeconds: null, ...overrides };
}

const t = (locale: Locale) => messagesFor(locale).auth;

function emailInput(locale: Locale = "vi") {
  return screen.getByLabelText(t(locale).email) as HTMLInputElement;
}

function handleInput(locale: Locale = "vi") {
  return screen.getByLabelText(t(locale).handle) as HTMLInputElement;
}

function passwordInput(locale: Locale = "vi") {
  return screen.getByLabelText(t(locale).password) as HTMLInputElement;
}

function description(input: HTMLElement): string | null | undefined {
  return document.getElementById(input.getAttribute("aria-describedby") ?? "")?.textContent;
}

// One second at a time: each tick schedules the next one when React has rendered it.
async function tick(seconds: number) {
  for (let i = 0; i < seconds; i++) {
    await act(async () => vi.advanceTimersByTime(1000));
  }
}

async function submit(
  locale: Locale = "vi",
  mode: AuthMode = "login",
  email = "minhanh@gmail.com",
  password = "12345678",
  handle = "minhanh",
) {
  fireEvent.change(emailInput(locale), { target: { value: email } });
  if (mode === "register") {
    fireEvent.change(handleInput(locale), { target: { value: handle } });
  }
  fireEvent.change(passwordInput(locale), { target: { value: password } });
  await act(async () => {
    fireEvent.click(screen.getByRole("button", { name: t(locale)[mode].submit }));
  });
}

afterEach(() => {
  vi.useRealTimers();
});

describe("AuthForm", () => {
  it.each<[Locale, AuthMode, string]>([
    ["vi", "login", "current-password"],
    ["en", "login", "current-password"],
    ["vi", "register", "new-password"],
    ["en", "register", "new-password"],
  ])("%s %s: labelled fields with the right autocomplete", (locale, mode, passwordAutocomplete) => {
    renderForm({ locale, mode });
    expect(screen.getByRole("heading", { level: 1, name: t(locale)[mode].title })).toBeTruthy();
    expect(emailInput(locale).getAttribute("autocomplete")).toBe("email");
    expect(emailInput(locale).type).toBe("email");
    expect(passwordInput(locale).getAttribute("autocomplete")).toBe(passwordAutocomplete);
    expect(passwordInput(locale).type).toBe("password");
    expect(screen.getByRole("button", { name: t(locale)[mode].submit }).getAttribute("type")).toBe("submit");
    expect(screen.getByRole("link", { name: t(locale)[mode].switchLink })).toBeTruthy();
  });

  it.each<Locale>(["vi", "en"])("%s: register has a handle field with its hint; login has none", (locale) => {
    renderForm({ locale, mode: "register" });
    const input = handleInput(locale);
    expect(input.getAttribute("name")).toBe("handle");
    expect(input.type).toBe("text");
    // A handle is a screen name (HTML's "nickname"); "username" would be saved with the password and filled into the
    // email field of /login.
    expect(input.getAttribute("autocomplete")).toBe("nickname");
    expect(input.getAttribute("autocapitalize")).toBe("none");
    expect(input.hasAttribute("maxlength")).toBe(false);
    expect(description(input)).toBe(t(locale).handleHint);
    cleanup();
    renderForm({ locale, mode: "login" });
    expect(screen.queryByLabelText(t(locale).handle)).toBeNull();
    expect(document.querySelector('input[name="handle"]')).toBeNull();
  });

  it.each([
    ["empty", ""],
    ["blank", "   "],
    ["too short", "ab"],
    ["starting with _", "_bob"],
    ["with an accent", "bób"],
    ["of the generated form", "U_0123456789AB"],
    ["of 31 characters", "a".repeat(31)],
  ])("checks the handle before sending: %s never reaches the action", async (_name, handle) => {
    const action = renderForm({ mode: "register" });
    await submit("vi", "register", "minhanh@gmail.com", "12345678", handle);
    expect(action).not.toHaveBeenCalled();
    expect(handleInput().getAttribute("aria-invalid")).toBe("true");
    expect(description(handleInput())).toBe(t("vi").errors.INVALID_HANDLE);
    expect(document.activeElement).toBe(handleInput());
  });

  it("sends a handle in upper case with spaces around it, leaving its normal form to the action", async () => {
    const action = renderForm({ mode: "register", action: vi.fn<Action>(async () => state({})) });
    await submit("vi", "register", "minhanh@gmail.com", "12345678", "  MinhAnh_2 ");
    expect(action).toHaveBeenCalledOnce();
    expect(vi.mocked(action).mock.calls[0]?.[1].get("handle")).toBe("  MinhAnh_2 ");
  });

  it.each<[Locale, "INVALID_HANDLE" | "HANDLE_ALREADY_TAKEN"]>([
    ["vi", "INVALID_HANDLE"],
    ["en", "INVALID_HANDLE"],
    ["vi", "HANDLE_ALREADY_TAKEN"],
    ["en", "HANDLE_ALREADY_TAKEN"],
  ])("%s: %s of the server shows on the handle field, keeps the handle and takes the focus", async (locale, code) => {
    renderForm({
      locale,
      mode: "register",
      action: async () => state({ email: "minhanh@gmail.com", handle: "minhanh", fieldErrors: { handle: code } }),
    });
    await submit(locale, "register");
    const input = handleInput(locale);
    expect(input.getAttribute("aria-invalid")).toBe("true");
    expect(description(input)).toBe(t(locale).errors[code]);
    expect(input.value).toBe("minhanh");
    expect(emailInput(locale).getAttribute("aria-invalid")).toBeNull();
    expect(document.activeElement).toBe(input);
  });

  it.each<[Locale, RegExp, RegExp]>([
    ["vi", /8–128 ký tự/, /ít nhất 8/i],
    ["en", /8–128 characters/, /at least 8/i],
  ])("%s: a password over 128 characters is refused with the 8–128 rule", async (locale, rule, minOnly) => {
    renderForm({
      locale,
      mode: "register",
      action: async () => state({ email: "minhanh@gmail.com", fieldErrors: { password: "INVALID_PASSWORD" } }),
    });
    await submit(locale, "register", "minhanh@gmail.com", "x".repeat(129));
    const message = description(passwordInput(locale)) ?? "";
    expect(message).toMatch(rule);
    expect(message).not.toMatch(minOnly);
  });

  it("describes the register password by its hint", () => {
    renderForm({ mode: "register" });
    expect(description(passwordInput())).toBe(t("vi").passwordHint);
  });

  it("carries next in a hidden field and in the link to the other form, encoded", () => {
    const next = "/following?cursor=a&b=1";
    renderForm({ next });
    const hidden = document.querySelector<HTMLInputElement>('input[type="hidden"][name="next"]');
    expect(hidden?.value).toBe(next);
    const link = screen.getByRole("link", { name: t("vi").login.switchLink });
    expect(link.getAttribute("href")).toBe(`/register?${new URLSearchParams({ next })}`);
  });

  it("has no next field without a next query", () => {
    renderForm();
    expect(document.querySelector('input[name="next"]')).toBeNull();
    expect(screen.getByRole("link", { name: t("vi").login.switchLink }).getAttribute("href")).toBe("/register");
  });

  it("checks the fields before sending: a malformed email and a short password never reach the action", async () => {
    const action = renderForm();
    await submit("vi", "login", "minhanh@gmail", "1234");
    expect(action).not.toHaveBeenCalled();
    expect(emailInput().getAttribute("aria-invalid")).toBe("true");
    expect(description(emailInput())).toBe(t("vi").errors.INVALID_EMAIL);
    expect(passwordInput().getAttribute("aria-invalid")).toBe("true");
    expect(description(passwordInput())).toBe(t("vi").errors.INVALID_PASSWORD);
    expect(document.activeElement).toBe(emailInput());
  });

  it.each<AuthMode>(["login", "register"])(
    "%s: sends a password of 65 characters outside the BMP whole, leaving its length to the server",
    async (mode) => {
      // 65 code points, 130 UTF-16 units: within the server's 128 characters, past a maxLength of 128.
      const password = "😀".repeat(65);
      const action = renderForm({ mode, action: vi.fn<Action>(async () => state({})) });
      expect(passwordInput().hasAttribute("maxlength")).toBe(false);
      await submit("vi", mode, "minhanh@gmail.com", password);
      expect(action).toHaveBeenCalledOnce();
      expect(vi.mocked(action).mock.calls[0]?.[1].get("password")).toBe(password);
    },
  );

  it("sends valid fields to the action", async () => {
    const action = renderForm({ next: "/following", action: vi.fn<Action>(async () => state({})) });
    await submit();
    expect(action).toHaveBeenCalledOnce();
    const form = vi.mocked(action).mock.calls[0]?.[1];
    expect(form?.get("email")).toBe("minhanh@gmail.com");
    expect(form?.get("password")).toBe("12345678");
    expect(form?.get("next")).toBe("/following");
  });

  it.each<[Locale, "email" | "password"]>([
    ["vi", "email"],
    ["en", "email"],
    ["vi", "password"],
    ["en", "password"],
  ])("%s: a field error of the server shows on the %s field and takes the focus", async (locale, field) => {
    const fieldErrors: AuthState["fieldErrors"] =
      field === "email" ? { email: "INVALID_EMAIL" } : { password: "INVALID_PASSWORD" };
    renderForm({ locale, action: async () => state({ email: "minhanh@gmail.com", fieldErrors }) });
    await submit(locale);
    const input = field === "email" ? emailInput(locale) : passwordInput(locale);
    expect(input.getAttribute("aria-invalid")).toBe("true");
    expect(description(input)).toBe(
      field === "email" ? t(locale).errors.INVALID_EMAIL : t(locale).errors.INVALID_PASSWORD,
    );
    expect(document.activeElement).toBe(input);
  });

  it.each<[Locale, AuthFormErrorCode & ("INVALID_CREDENTIALS" | "UNAVAILABLE")]>([
    ["vi", "INVALID_CREDENTIALS"],
    ["en", "INVALID_CREDENTIALS"],
    ["vi", "UNAVAILABLE"],
    ["en", "UNAVAILABLE"],
  ])("%s: %s is an alert with a title and a body", async (locale, code) => {
    renderForm({ locale, action: async () => state({ email: "minhanh@gmail.com", formError: code }) });
    await submit(locale);
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain(t(locale).errors[code].title);
    expect(alert.textContent).toContain(t(locale).errors[code].body);
    // An icon as well as the color.
    expect(alert.querySelector("svg")).not.toBeNull();
  });

  it("gives one message for a wrong email and a wrong password, not which one", async () => {
    renderForm({ action: async () => state({ formError: "INVALID_CREDENTIALS" }) });
    await submit();
    expect(screen.getByRole("alert").textContent).toBe(
      t("vi").errors.INVALID_CREDENTIALS.title + t("vi").errors.INVALID_CREDENTIALS.body,
    );
  });

  it.each<Locale>(["vi", "en"])(
    "%s: an email already in use shows on the email field with a login link",
    async (locale) => {
      renderForm({
        locale,
        mode: "register",
        next: "/following",
        action: async () => state({ email: "minhanh@gmail.com", formError: "EMAIL_ALREADY_REGISTERED" }),
      });
      await submit(locale, "register");
      const note = document.getElementById(emailInput(locale).getAttribute("aria-describedby") ?? "");
      expect(note?.textContent).toContain(t(locale).errors.EMAIL_ALREADY_REGISTERED);
      const link = within(note as HTMLElement).getByRole("link", { name: t(locale).errors.emailTakenLogin });
      expect(link.getAttribute("href")).toBe(`/login?${new URLSearchParams({ next: "/following" })}`);
      expect(emailInput(locale).getAttribute("aria-invalid")).toBe("true");
    },
  );

  it("keeps the email after a failed answer and never fills the password back in", async () => {
    renderForm({ action: async () => state({ email: "minhanh@gmail.com", formError: "INVALID_CREDENTIALS" }) });
    await submit();
    expect(emailInput().value).toBe("minhanh@gmail.com");
    expect(passwordInput().value).toBe("");
    expect(document.body.innerHTML).not.toContain("12345678");
  });

  it("shows the sending state while the action runs", async () => {
    let finish: (value: AuthState) => void = () => {};
    renderForm({ action: () => new Promise<AuthState>((resolve) => (finish = resolve)) });
    await submit();
    const button = screen.getByRole("button", { name: t("vi").login.submitting });
    expect(button.getAttribute("aria-busy")).toBe("true");
    expect((button as HTMLButtonElement).disabled).toBe(true);
    await act(async () => finish(state({ formError: "UNAVAILABLE" })));
    expect(screen.getByRole("button", { name: t("vi").login.submit })).toBeTruthy();
  });

  it.each<Locale>(["vi", "en"])("%s: RATE_LIMITED counts down on a locked button, then unlocks it", async (locale) => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const messages = t(locale);
    const label = (seconds: number) =>
      locale === "vi"
        ? `Thử lại sau ${seconds} giây`
        : `Try again in ${seconds} ${seconds === 1 ? "second" : "seconds"}`;
    renderForm({ locale, action: async () => state({ formError: "RATE_LIMITED", retryAfterSeconds: 2 }) });
    await submit(locale);

    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain(messages.errors.RATE_LIMITED.title);
    let button = screen.getByRole("button", { name: label(2) });
    expect((button as HTMLButtonElement).disabled).toBe(true);

    await tick(1);
    button = screen.getByRole("button", { name: label(1) });
    expect((button as HTMLButtonElement).disabled).toBe(true);

    await tick(1);
    button = screen.getByRole("button", { name: messages.login.submit });
    expect((button as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("unlocks the button by the clock, not by the number of timer callbacks", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    renderForm({ action: async () => state({ formError: "RATE_LIMITED", retryAfterSeconds: 7 }) });
    await submit();
    expect(screen.getByRole("button", { name: "Thử lại sau 7 giây" })).toBeTruthy();
    // The app sits in the background for 10 s with its timers paused; back in front, one callback comes late.
    vi.setSystemTime(Date.now() + 9000);
    await tick(1);
    expect((screen.getByRole("button", { name: t("vi").login.submit }) as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("announces the wait once: the ticking count is hidden from screen readers", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    renderForm({ action: async () => state({ formError: "RATE_LIMITED", retryAfterSeconds: 42 }) });
    await submit();
    await tick(2);
    const alert = screen.getByRole("alert");
    expect(alert.querySelector(".sr-only")?.textContent).toBe("Thử lại sau 42 giây.");
    expect(alert.querySelector('[aria-hidden="true"].tabular-nums')?.textContent).toBe("Thử lại sau 40 giây.");
  });

  it("starts the wait again on a second RATE_LIMITED with the same seconds", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    renderForm({ action: async () => state({ formError: "RATE_LIMITED", retryAfterSeconds: 2 }) });
    await submit();
    await tick(2);
    await submit();
    expect(screen.getByRole("button", { name: "Thử lại sau 2 giây" })).toBeTruthy();
  });

  it("RATE_LIMITED without a wait leaves the button usable", async () => {
    renderForm({ action: async () => state({ formError: "RATE_LIMITED" }) });
    await submit();
    expect(screen.getByRole("alert").textContent).toContain(t("vi").errors.RATE_LIMITED.bodyNoTime);
    expect((screen.getByRole("button", { name: t("vi").login.submit }) as HTMLButtonElement).disabled).toBe(false);
  });

  it.each<Locale>(["vi", "en"])(
    "%s: shows and hides the password with a toggle of one fixed name, pressed while it shows",
    (locale) => {
      renderForm({ locale });
      const toggle = screen.getByRole("button", { name: t(locale).showPassword });
      expect(toggle.getAttribute("aria-pressed")).toBe("false");
      fireEvent.click(toggle);
      expect(passwordInput(locale).type).toBe("text");
      // The same button, same name: only the pressed state changes.
      expect(screen.getByRole("button", { name: t(locale).showPassword })).toBe(toggle);
      expect(toggle.getAttribute("aria-pressed")).toBe("true");
      fireEvent.click(toggle);
      expect(passwordInput(locale).type).toBe("password");
      expect(toggle.getAttribute("aria-pressed")).toBe("false");
    },
  );
});
