import { fireEvent, render, screen } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import type { ReactNode } from "react";
import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { messagesFor } from "@/i18n/messages";
import { DropZone } from "./drop-zone";
import { UploadFrame } from "./upload-frame";
import { UploadProgress } from "./upload-progress";
import { UploadResult } from "./upload-result";

const t = messagesFor("vi").upload;

const intl = (children: ReactNode) => (
  <NextIntlClientProvider locale="vi" messages={{ upload: t }}>
    {children}
  </NextIntlClientProvider>
);

const progress = (value: number) => (
  <UploadProgress
    heading="Đang tải lên (30%)"
    progress={value}
    paused={false}
    meta="5,8 / 19,2 MB"
    videoTitle="Chiều"
    fileMeta="clip.mp4 · 19,2 MB"
    onCancel={() => {}}
  />
);

describe("upload components", () => {
  it("marks the current step and links the close button home", () => {
    render(intl(<UploadFrame step={2}>body</UploadFrame>));
    const steps = screen.getAllByRole("listitem");
    expect(steps.map((step) => step.getAttribute("aria-current"))).toEqual([null, "step", null]);
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    expect(screen.getByRole("link", { name: t.close }).getAttribute("href")).toBe("/");
  });

  it("server-renders the progress bar without a style attribute (CSP), then sizes it through the DOM", () => {
    expect(renderToString(intl(progress(0.3)))).not.toContain("style=");
    const { rerender } = render(intl(progress(0.3)));
    const bar = screen.getByRole("progressbar", { name: t.progress.label });
    expect(bar.getAttribute("aria-valuenow")).toBe("30");
    expect((bar.firstElementChild as HTMLElement).style.width).toBe("30%");
    rerender(intl(progress(0.75)));
    expect((bar.firstElementChild as HTMLElement).style.width).toBe("75%");
  });

  it("offers Retry only when given one, and always Cancel with its note", () => {
    const onRetry = vi.fn();
    const onCancel = vi.fn();
    render(
      intl(
        <UploadProgress
          heading="x"
          progress={0}
          paused
          meta="m"
          videoTitle="v"
          fileMeta="f"
          onCancel={onCancel}
          onRetry={onRetry}
        />,
      ),
    );
    fireEvent.click(screen.getByRole("button", { name: t.progress.retry }));
    fireEvent.click(screen.getByRole("button", { name: t.progress.cancel }));
    expect(onRetry).toHaveBeenCalledTimes(1);
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(screen.getByText(t.progress.cancelNote)).toBeTruthy();
  });

  it("shows the next steps of each processing state", () => {
    const { rerender } = render(
      intl(<UploadResult state="processing" fileMeta="f" videoHref={null} onRestart={() => {}} />),
    );
    expect(screen.queryByRole("link", { name: t.result.watch })).toBeNull();
    expect(screen.getByRole("link", { name: t.result.myVideos }).getAttribute("href")).toBe("/me");
    rerender(intl(<UploadResult state="ready" fileMeta="f" videoHref="/v/abc" onRestart={() => {}} />));
    expect(screen.getByRole("link", { name: t.result.watch }).getAttribute("href")).toBe("/v/abc");
    expect(screen.getByRole("button", { name: t.result.another })).toBeTruthy();
    rerender(intl(<UploadResult state="failed" fileMeta="f" videoHref={null} onRestart={() => {}} />));
    expect(screen.getByText(t.result.failedTitle)).toBeTruthy();
    expect(screen.getByRole("button", { name: t.result.pickAnother })).toBeTruthy();
  });

  it("highlights the zone while a file is dragged over it and hands the dropped file over", () => {
    const onFile = vi.fn();
    render(intl(<DropZone onFile={onFile} checking={false} />));
    const zone = screen.getByTestId("drop-zone");
    const file = new File(["x"], "clip.mp4", { type: "video/mp4" });
    fireEvent.dragOver(zone, { dataTransfer: { types: ["Files"], files: [] } });
    expect(screen.getByText(t.pick.drop)).toBeTruthy();
    fireEvent.dragLeave(zone, { relatedTarget: null });
    expect(screen.queryByText(t.pick.drop)).toBeNull();
    fireEvent.drop(zone, { dataTransfer: { types: ["Files"], files: [file] } });
    expect(onFile).toHaveBeenCalledWith(file);
  });

  it("ignores a drag of something that is not a file", () => {
    render(intl(<DropZone onFile={() => {}} checking={false} />));
    fireEvent.dragOver(screen.getByTestId("drop-zone"), { dataTransfer: { types: ["text/plain"], files: [] } });
    expect(screen.queryByText(t.pick.drop)).toBeNull();
  });
});
