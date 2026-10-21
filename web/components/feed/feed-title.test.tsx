import { fireEvent, render, screen } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { afterAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import { FeedTitle } from "./feed-title";

// jsdom lays nothing out: the observer reports at once, and the text is as tall as `textHeight`.
let textHeight = 0;
class FakeResizeObserver {
  constructor(private readonly callback: ResizeObserverCallback) {}
  observe() {
    this.callback([], this as unknown as ResizeObserver);
  }
  disconnect() {}
}

function renderTitle(title: string, locale: Locale = "vi") {
  render(
    <NextIntlClientProvider locale={locale} messages={{ feed: messagesFor(locale).feed }}>
      <FeedTitle title={title} />
    </NextIntlClientProvider>,
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
  vi.stubGlobal("ResizeObserver", FakeResizeObserver);
  vi.spyOn(HTMLElement.prototype, "scrollHeight", "get").mockImplementation(() => textHeight);
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(44);
});

afterAll(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("FeedTitle", () => {
  it.each<Locale>(["vi", "en"])("%s: a title longer than two lines expands and collapses", (locale) => {
    textHeight = 120;
    renderTitle("Chiều Hà Nội cuối thu, gió heo may về trên phố cổ.", locale);
    const feed = messagesFor(locale).feed;
    const button = screen.getByRole("button", { expanded: false });
    expect(button.textContent).toContain(feed.titleMore);
    fireEvent.click(button);
    expect(screen.getByRole("button", { expanded: true }).textContent).toContain(feed.titleLess);
  });

  it("a short title has nothing to expand", () => {
    textHeight = 22;
    renderTitle("Ngắn");
    const button = screen.getByRole("button", { name: "Ngắn" });
    expect(button.hasAttribute("aria-expanded")).toBe(false);
    expect(button).toHaveProperty("disabled", true);
  });

  it("an empty title renders nothing", () => {
    renderTitle("");
    expect(screen.queryByRole("button")).toBeNull();
  });
});
