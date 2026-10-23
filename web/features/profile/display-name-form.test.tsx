import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { describe, expect, it, vi } from "vitest";
import { messagesFor } from "@/i18n/messages";
import { initialDisplayNameState, type DisplayNameState } from "./display-name";
import { DisplayNameForm } from "./display-name-form";

const t = messagesFor("vi").profile.displayName;

function renderForm(
  action: (previous: DisplayNameState, form: FormData) => Promise<DisplayNameState>,
  current = "Lan",
) {
  return render(
    <NextIntlClientProvider locale="vi" messages={{ profile: messagesFor("vi").profile }}>
      <DisplayNameForm current={current} action={action} />
    </NextIntlClientProvider>,
  );
}

const field = () => screen.getByLabelText(t.label) as HTMLInputElement;
const submit = () => screen.getByRole("button", { name: t.submit }) as HTMLButtonElement;

function type(value: string) {
  fireEvent.change(field(), { target: { value } });
}

const answer = (patch: Partial<DisplayNameState>): DisplayNameState => ({ ...initialDisplayNameState, ...patch });

describe("DisplayNameForm", () => {
  it("starts from the current name, behind a disclosure", () => {
    const { container } = renderForm(vi.fn());
    expect(screen.getByText(t.summary).tagName).toBe("SUMMARY");
    expect(container.querySelector("details")?.open).toBe(false);
    expect(field().value).toBe("Lan");
    expect(field().name).toBe("display_name");
  });

  it.each([
    ["   ", "REQUIRED"],
    ["Đ".repeat(51), "TOO_LONG"],
    ["Lan‮Phương", "INVALID_CHARACTERS"],
    // Looks empty: a Hangul filler, then joiners alone.
    ["\u3164", "INVALID_CHARACTERS"],
    ["\u200d\ufe0f", "INVALID_CHARACTERS"],
  ] as const)("checks %j before sending: %s on the field", (value, error) => {
    const action = vi.fn();
    renderForm(action);
    type(value);
    fireEvent.click(submit());
    expect(action).not.toHaveBeenCalled();
    expect(screen.getByText(t.errors[error])).toBeTruthy();
    expect(field().getAttribute("aria-invalid")).toBe("true");
    expect(document.activeElement).toBe(field());
  });

  it("sends the name to the action and confirms the change", async () => {
    const action = vi.fn(async (_previous: DisplayNameState, form: FormData) =>
      answer({ value: String(form.get("display_name")), saved: String(form.get("display_name")) }),
    );
    renderForm(action);
    type("<b>Lan Phương</b>");
    await act(async () => fireEvent.click(submit()));
    await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
    expect(action.mock.calls[0]![1].get("display_name")).toBe("<b>Lan Phương</b>");
    expect((await screen.findByRole("status")).textContent).toContain(t.saved);
  });

  it("shows user-service refusing the name on the field", async () => {
    renderForm(async () => answer({ value: "Lan", fieldError: "INVALID_DISPLAY_NAME" }));
    await act(async () => fireEvent.click(submit()));
    expect(await screen.findByText(t.errors.INVALID_DISPLAY_NAME)).toBeTruthy();
  });

  it("locks the button for the Retry-After of a rate limit", async () => {
    renderForm(async () => answer({ value: "Lan", formError: "RATE_LIMITED", retryAfterSeconds: 30 }));
    await act(async () => fireEvent.click(submit()));
    const alert = await screen.findByRole("alert");
    expect(alert.textContent).toBe(t.errors.RATE_LIMITED.replace("{seconds}", "30"));
    expect(submit().disabled).toBe(true);
  });

  it("says when the name could not be changed", async () => {
    renderForm(async () => answer({ value: "Lan", formError: "UNAVAILABLE" }));
    await act(async () => fireEvent.click(submit()));
    expect((await screen.findByRole("alert")).textContent).toBe(t.errors.UNAVAILABLE);
    expect(submit().disabled).toBe(false);
  });
});
