import { render, screen, within } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import type { VideoStatus } from "@/features/profile/api";
import { messagesFor } from "@/i18n/messages";
import { MyAccount } from "./my-account";
import { MyVideoRow } from "./my-video-row";
import { ProfileNotFound } from "./profile-states";
import { StatusBadge } from "./status-badge";

const t = messagesFor("vi").profile;
const userId = "0192f0c1-7a3e-7c4b-9d2e-000000000001";

function withMessages(children: ReactNode) {
  return render(
    <NextIntlClientProvider locale="vi" messages={{ profile: messagesFor("vi").profile }}>
      {children}
    </NextIntlClientProvider>,
  );
}

describe("MyAccount", () => {
  it("has a log out button posting to /logout, shown on small screens where the bottom bar has none", () => {
    withMessages(<MyAccount userId={userId} account={{ displayName: "Lan Phương", handle: "lanphuong" }} />);
    const button = screen.getByRole("button", { name: t.my.logout });
    expect(button.getAttribute("type")).toBe("submit");
    const form = button.closest("form");
    expect(form?.getAttribute("method")).toBe("post");
    expect(form?.getAttribute("action")).toBe("/logout");
    // Hidden from the md breakpoint on only: the side bar of wide screens has its own.
    expect(form?.className.split(" ")).toEqual(["md:hidden"]);
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe(t.my.title);
  });

  it("shows the name as text and the handle, with an upload link for wide screens", () => {
    withMessages(
      <MyAccount userId={userId} account={{ displayName: "<img src=x onerror=alert(1)>", handle: "lanphuong" }} />,
    );
    expect(screen.getByText("<img src=x onerror=alert(1)>").tagName).toBe("BDI");
    expect(document.querySelector("img")).toBeNull();
    expect(screen.getByText("@lanphuong")).toBeTruthy();
    expect(screen.getByRole("link", { name: t.my.upload }).getAttribute("href")).toBe("/upload");
  });

  it("shows the avatar alone when the profile is not known, and keeps log out", () => {
    const { container } = withMessages(<MyAccount userId={userId} account={null} />);
    expect(container.textContent).not.toContain("@");
    expect(screen.getByRole("button", { name: t.my.logout })).toBeTruthy();
  });
});

describe("StatusBadge", () => {
  it.each<VideoStatus>(["UPLOADING", "PROCESSING", "READY", "FAILED"])("shows %s with an icon and a word", (status) => {
    const { container } = withMessages(<StatusBadge status={status} />);
    const badge = container.firstElementChild as HTMLElement;
    expect(badge.textContent).toBe(t.status[status]);
    expect(within(badge).getByText(t.status[status])).toBeTruthy();
    expect(badge.querySelector("svg[aria-hidden='true']")).not.toBeNull();
  });
});

describe("ProfileNotFound", () => {
  it("has the profile's own words and a way home", () => {
    withMessages(<ProfileNotFound />);
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe(t.notFound.title);
    expect(screen.getByText(t.notFound.body)).toBeTruthy();
    expect(screen.getByRole("link", { name: t.notFound.home }).getAttribute("href")).toBe("/");
  });
});

describe("MyVideoRow", () => {
  // Display utilities without a breakpoint: two on one element fight, and the one Tailwind emits last wins whatever
  // the class order says.
  const baseDisplays = new Set([
    "hidden",
    "block",
    "inline",
    "inline-block",
    "flex",
    "inline-flex",
    "grid",
    "contents",
  ]);
  const displaysOf = (element: Element) =>
    (element.getAttribute("class") ?? "").split(/\s+/).filter((name) => baseDisplays.has(name));

  it("shows one status badge at a time: under the title on phones, in the status column on wide screens", () => {
    const { container } = withMessages(
      <ul>
        <MyVideoRow
          title="Video 1"
          status="READY"
          href="/v/1"
          thumbnailUrl={null}
          duration="0:58"
          views="8,3 N lượt xem"
          publishedAgo="3 ngày trước"
          progress={null}
        />
      </ul>,
    );
    const badges = screen.getAllByText(t.status.READY);
    expect(badges).toHaveLength(2);
    const [phone, wide] = badges.map((badge) => (badge.getAttribute("class") ?? "").split(/\s+/));
    expect(phone).toContain("md:hidden");
    expect(phone).not.toContain("max-md:hidden");
    expect(wide).toContain("max-md:hidden");
    expect(wide).not.toContain("md:hidden");
    for (const element of container.querySelectorAll("*")) {
      expect(displaysOf(element).length, element.outerHTML).toBeLessThanOrEqual(1);
    }
  });
});
