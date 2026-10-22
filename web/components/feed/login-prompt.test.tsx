import { fireEvent, render, screen, within } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import { messagesFor } from "@/i18n/messages";
import { LoginPrompt } from "./login-prompt";

const t = messagesFor("vi").share.prompt;

// A page with a control before and after the prompt, as the share page has its header links and video controls.
function Page() {
  const [open, setOpen] = useState(false);
  return (
    <NextIntlClientProvider locale="vi" messages={{ share: messagesFor("vi").share }}>
      <button type="button">Header</button>
      <button type="button" onClick={() => setOpen(true)}>
        Like
      </button>
      {open && <LoginPrompt reason="like" loginHref="/login" registerHref="/register" onClose={() => setOpen(false)} />}
      <button type="button">Video controls</button>
    </NextIntlClientProvider>
  );
}

function openPrompt() {
  render(<Page />);
  const opener = screen.getByRole("button", { name: "Like" });
  opener.focus();
  fireEvent.click(opener);
  const dialog = screen.getByRole("dialog", { name: t.likeTitle });
  return {
    opener,
    dialog,
    close: within(dialog).getByRole("button", { name: t.close }),
    logIn: within(dialog).getByRole("link", { name: t.logIn }),
    register: within(dialog).getByRole("link", { name: t.register }),
    later: within(dialog).getByRole("button", { name: t.later }),
  };
}

// Tab as the browser sees it: the keydown reaches the focused element first. jsdom never moves focus on Tab itself;
// returns whether the prompt cancelled the key, which stops the browser from moving focus where it would.
function tab(shiftKey = false) {
  const target = document.activeElement ?? document.body;
  return !fireEvent.keyDown(target, { key: "Tab", shiftKey });
}

describe("LoginPrompt focus", () => {
  it("starts on Đăng nhập and wraps Tab from the last control to the first", () => {
    const { close, logIn, later } = openPrompt();
    expect(document.activeElement).toBe(logIn);

    // Inside the prompt the browser moves focus itself.
    expect(tab()).toBe(false);
    later.focus();
    expect(tab()).toBe(true);
    expect(document.activeElement).toBe(close);
  });

  it("wraps Shift+Tab from the first control to the last", () => {
    const { close, later } = openPrompt();
    close.focus();
    expect(tab(true)).toBe(true);
    expect(document.activeElement).toBe(later);
  });

  it("skips a control the screen size hides", () => {
    const { close, register, later } = openPrompt();
    // A wide screen: "Later" is display: none (md:hidden).
    later.style.display = "none";
    register.focus();
    expect(tab()).toBe(true);
    expect(document.activeElement).toBe(close);
    expect(tab(true)).toBe(true);
    expect(document.activeElement).toBe(register);
  });

  it("brings focus back in when it is outside the prompt", () => {
    const { close, later } = openPrompt();
    (document.activeElement as HTMLElement).blur();
    expect(tab()).toBe(true);
    expect(document.activeElement).toBe(close);
    (document.activeElement as HTMLElement).blur();
    expect(tab(true)).toBe(true);
    expect(document.activeElement).toBe(later);
  });

  it("closes on Escape and gives focus back to the button that opened it", () => {
    const { opener } = openPrompt();
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(document.activeElement).toBe(opener);
  });
});
