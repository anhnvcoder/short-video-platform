import { fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { Avatar, avatarHue, Button, Field, Input, Spinner, TabPanel, Tabs, Toast, ToastRegion } from ".";

describe("Button", () => {
  it("is a plain button by default, so it never submits a form by accident", () => {
    render(<Button>Đăng video</Button>);
    expect(screen.getByRole("button", { name: "Đăng video" }).getAttribute("type")).toBe("button");
  });

  it("while loading is busy and blocks clicks", () => {
    const onClick = vi.fn();
    render(
      <Button loading onClick={onClick}>
        Đang gửi…
      </Button>,
    );
    const button = screen.getByRole("button", { name: "Đang gửi…" });
    expect(button.getAttribute("aria-busy")).toBe("true");
    expect((button as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(button);
    expect(onClick).not.toHaveBeenCalled();
  });
});

describe("Field", () => {
  it("labels its control and describes it by the error, marking it invalid", () => {
    render(
      <Field label="Email" hint="ten@gmail.com" error="Email không đúng định dạng.">
        {(control) => <Input type="email" {...control} />}
      </Field>,
    );
    const input = screen.getByLabelText("Email");
    expect(input.getAttribute("aria-invalid")).toBe("true");
    const note = document.getElementById(input.getAttribute("aria-describedby") ?? "");
    expect(note?.textContent).toBe("Email không đúng định dạng.");
    // The error replaces the hint.
    expect(screen.queryByText("ten@gmail.com")).toBeNull();
  });

  it("describes a valid control by its hint", () => {
    render(
      <Field label="Mật khẩu" hint="Ít nhất 8 ký tự.">
        {(control) => <Input type="password" {...control} />}
      </Field>,
    );
    const input = screen.getByLabelText("Mật khẩu");
    expect(input.hasAttribute("aria-invalid")).toBe(false);
    expect(document.getElementById(input.getAttribute("aria-describedby") ?? "")?.textContent).toBe("Ít nhất 8 ký tự.");
  });
});

function FeedTabs() {
  const [value, setValue] = useState("explore");
  return (
    <>
      <Tabs
        label="Chọn feed"
        idBase="feed"
        value={value}
        onChange={setValue}
        items={[
          { value: "following", label: "Đang theo dõi" },
          { value: "explore", label: "Khám phá" },
        ]}
      />
      <TabPanel idBase="feed" value={value}>
        {value}
      </TabPanel>
    </>
  );
}

describe("Tabs", () => {
  it("follows the WAI-ARIA tabs pattern", () => {
    render(<FeedTabs />);
    expect(screen.getByRole("tablist", { name: "Chọn feed" })).toBeTruthy();
    const explore = screen.getByRole("tab", { name: "Khám phá" });
    const following = screen.getByRole("tab", { name: "Đang theo dõi" });
    expect(explore.getAttribute("aria-selected")).toBe("true");
    expect(explore.tabIndex).toBe(0);
    expect(following.getAttribute("aria-selected")).toBe("false");
    expect(following.tabIndex).toBe(-1);
    const panel = screen.getByRole("tabpanel", { name: "Khám phá" });
    expect(explore.getAttribute("aria-controls")).toBe(panel.id);
  });

  it("moves focus and selection with the arrow keys, wrapping around, and with Home/End", () => {
    render(<FeedTabs />);
    const explore = screen.getByRole("tab", { name: "Khám phá" });
    fireEvent.keyDown(explore, { key: "ArrowRight" });
    const following = screen.getByRole("tab", { name: "Đang theo dõi" });
    expect(following.getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(following);
    fireEvent.keyDown(following, { key: "End" });
    expect(screen.getByRole("tab", { name: "Khám phá" }).getAttribute("aria-selected")).toBe("true");
    fireEvent.keyDown(screen.getByRole("tab", { name: "Khám phá" }), { key: "Home" });
    expect(screen.getByRole("tab", { name: "Đang theo dõi" }).getAttribute("aria-selected")).toBe("true");
  });
});

describe("Avatar", () => {
  const id = "0192f0c1-7a3e-7c4b-9d2e-5f6a7b8c9d0e";

  it("gets the same hue for the same id, within the 8 hues", () => {
    expect(avatarHue(id)).toBe(avatarHue(id));
    const seen = new Set(Array.from({ length: 200 }, (_, i) => avatarHue(`author-${i}`)));
    expect([...seen].every((hue) => hue >= 0 && hue < 8)).toBe(true);
    expect(seen.size).toBe(8);
  });

  it("shows the first letter of the name, or an icon without one", () => {
    const { container, rerender } = render(<Avatar seed={id} name="đức anh" />);
    expect(container.textContent).toBe("Đ");
    expect(container.firstElementChild?.className).toContain(`bg-avatar-${avatarHue(id)}`);
    rerender(<Avatar seed={id} />);
    expect(container.querySelector("svg")).not.toBeNull();
  });

  it("is decoration unless it has a label", () => {
    const { container, rerender } = render(<Avatar seed={id} />);
    expect(container.firstElementChild?.getAttribute("aria-hidden")).toBe("true");
    rerender(<Avatar seed={id} label="Tác giả" />);
    expect(screen.getByRole("img", { name: "Tác giả" })).toBeTruthy();
  });
});

describe("Toast", () => {
  it("lives in a polite live region and runs its action", () => {
    const onClick = vi.fn();
    render(
      <ToastRegion label="Thông báo">
        <Toast tone="danger" action={{ label: "Thử lại", onClick }}>
          Chưa thích được video. Đã hoàn tác.
        </Toast>
      </ToastRegion>,
    );
    const region = screen.getByRole("status", { name: "Thông báo" });
    expect(region.getAttribute("aria-live")).toBe("polite");
    expect(region.textContent).toContain("Chưa thích được video. Đã hoàn tác.");
    fireEvent.click(screen.getByRole("button", { name: "Thử lại" }));
    expect(onClick).toHaveBeenCalledOnce();
  });
});

describe("Spinner", () => {
  it("is announced only with a label", () => {
    const { rerender } = render(<Spinner />);
    expect(screen.queryByRole("status")).toBeNull();
    rerender(<Spinner label="Đang tải…" />);
    expect(screen.getByRole("status").textContent).toBe("Đang tải…");
  });
});
