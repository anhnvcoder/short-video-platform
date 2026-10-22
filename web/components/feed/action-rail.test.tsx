import { render, screen } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { describe, expect, it } from "vitest";
import type { Locale } from "@/i18n/config";
import { messagesFor } from "@/i18n/messages";
import { ActionRail } from "./action-rail";

function renderRail(locale: Locale, liked: boolean, likeCount: number | null) {
  render(
    <NextIntlClientProvider locale={locale} messages={{ feed: messagesFor(locale).feed }}>
      <ActionRail
        authorId="0192f0c1-7a3e-7c4b-9d2e-000000000002"
        follow={null}
        locked={false}
        liked={liked}
        likeCount={likeCount}
        viewCount={null}
        onLike={() => {}}
        onShare={() => {}}
      />
    </NextIntlClientProvider>,
  );
  return screen.getByRole("button", { pressed: liked });
}

describe("ActionRail like button", () => {
  // A toggle: the same name in both states, and aria-pressed alone tells whether the video is liked, so a screen reader
  // never reads "Unlike video, pressed". The name holds the text the button shows (WCAG 2.5.3, axe's
  // label-content-name-mismatch), so a voice user who says what they see reaches it.
  it.each<[Locale, boolean, number | null, string, string]>([
    ["vi", false, 12_400, "Thích video, 12,4 N", "12,4 N"],
    ["vi", true, 12_401, "Thích video, 12,4 N", "12,4 N"],
    ["vi", false, null, "Thích video", "Thích"],
    ["vi", true, null, "Thích video", "Thích"],
    ["en", false, 3, "Like video, 3", "3"],
    ["en", true, 12_400, "Like video, 12.4K", "12.4K"],
    ["en", false, null, "Like video", "Like"],
    ["en", true, null, "Like video", "Like"],
  ])("%s, liked %s, count %s: named %j, shows %j", (locale, liked, count, name, shown) => {
    const like = renderRail(locale, liked, count);
    expect(like.getAttribute("aria-label")).toBe(name);
    expect(like.getAttribute("aria-pressed")).toBe(String(liked));
    expect(like.textContent).toBe(shown);
    expect(name).toContain(shown);
  });

  it.each<Locale>(["vi", "en"])("%s: the share button's name holds the text it shows", (locale) => {
    renderRail(locale, false, null);
    const messages = messagesFor(locale).feed;
    const share = screen.getByRole("button", { name: messages.shareLabel });
    expect(share.textContent).toBe(messages.share);
    expect(messages.shareLabel.toLowerCase()).toContain(messages.share.toLowerCase());
  });
});
