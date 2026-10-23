import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { useRouter } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { messagesFor } from "@/i18n/messages";
import { server } from "@/lib/test/msw-server";
import type { Video } from "./api";
import { readDuration } from "./file-checks";
import { FakeXHR } from "./testing/fake-xhr";
import { uploadStore } from "./upload-store";
import { UploadScreen } from "./upload-screen";

vi.mock("next/navigation", () => ({ useRouter: vi.fn() }));
// jsdom decodes no video: each test says what duration the browser would read.
vi.mock("./file-checks", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./file-checks")>()),
  readDuration: vi.fn(),
}));

const uploadOrigin = "http://127.0.0.1:9000";
const uploadUrl = `${uploadOrigin}/uploads`;
const videoId = "0192f0c1-0000-7000-8000-000000000001";
const secondId = "0192f0c1-0000-7000-8000-000000000002";
const router = { replace: vi.fn(), push: vi.fn() };
const t = messagesFor("vi").upload;

const problem = (status: number, code: string) =>
  HttpResponse.json(
    { type: "about:blank", title: "", status, detail: "", code },
    { status, headers: { "Content-Type": "application/problem+json" } },
  );

function video(id: string, status: Video["status"]): Video {
  return { video_id: id, author_id: secondId, title: "Chiều", status, created_at: "2026-10-22T08:00:00Z" };
}

// A file of `size` bytes without allocating them.
function fakeFile(name: string, type: string, size: number): File {
  const file = new File(["x"], name, { type });
  Object.defineProperty(file, "size", { value: size });
  return file;
}

const clip = () => fakeFile("chieu-ho-guom.mp4", "video/mp4", 20_132_659);

// POST /api/videos answers each call with the next answer (the last one from then on); a form answer creates the next
// video id.
function initServer(...answers: (() => Response)[]) {
  const bodies: unknown[] = [];
  server.use(
    http.post("*/api/videos", async ({ request }) => {
      bodies.push(await request.json());
      const answer = answers.length > 1 ? answers.shift() : answers[0];
      if (answer) {
        return answer();
      }
      const id = bodies.length === 1 ? videoId : secondId;
      return HttpResponse.json(
        {
          video_id: id,
          upload_url: uploadUrl,
          form_fields: { key: `uploads/${id}`, policy: "cG9saWN5", "x-amz-signature": "c2ln" },
          expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
        },
        { status: 201, headers: { Date: new Date().toUTCString() } },
      );
    }),
  );
  return bodies;
}

function processingServer(...statuses: (Video["status"] | (() => Response))[]) {
  const polls: number[] = [];
  server.use(
    http.post(`*/api/videos/:id/complete`, ({ params }) =>
      HttpResponse.json(video(String(params.id), "PROCESSING"), { status: 202 }),
    ),
    http.get(`*/api/videos/:id`, ({ params }) => {
      polls.push(Date.now());
      const answer = (statuses.length > 1 ? statuses.shift() : statuses[0]) ?? "PROCESSING";
      return typeof answer === "function" ? answer() : HttpResponse.json(video(String(params.id), answer));
    }),
  );
  return polls;
}

function renderScreen() {
  return render(
    <NextIntlClientProvider locale="vi" messages={{ upload: t }}>
      <QueryClientProvider client={new QueryClient()}>
        <UploadScreen uploadOrigin={uploadOrigin} />
      </QueryClientProvider>
    </NextIntlClientProvider>,
  );
}

beforeEach(() => {
  FakeXHR.reset();
  vi.stubGlobal("XMLHttpRequest", FakeXHR);
  vi.useFakeTimers({
    toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "Date", "performance"],
  });
  vi.setSystemTime(Date.parse("2026-10-22T08:00:00Z"));
  vi.mocked(useRouter).mockReturnValue(router as unknown as ReturnType<typeof useRouter>);
  vi.mocked(readDuration).mockResolvedValue(42);
  router.replace.mockReset();
});

afterEach(() => {
  for (const upload of uploadStore.list()) {
    uploadStore.dismiss(upload.key);
  }
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

// Lets requests, answers and renders finish. React Query hands results over on zero-delay timers, which the fake
// clock runs 1 ms later when they are set during a tick, so each round moves time on by 1 ms.
async function flush() {
  for (let round = 0; round < 10; round++) {
    await act(() => vi.advanceTimersByTimeAsync(1));
    await new Promise((resolve) => setImmediate(resolve));
  }
}

// Flush rounds until `done` holds, at most 100 (100 ms of the fake clock): a loaded machine may need more rounds than
// flush's fixed ten before the requests and renders a step waits for have run.
async function flushUntil(done: () => boolean, what: string) {
  for (let round = 0; round < 100; round++) {
    if (done()) {
      return;
    }
    await act(() => vi.advanceTimersByTimeAsync(1));
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`still waiting for ${what}`);
}

const alertText = () => screen.queryByRole("alert")?.textContent ?? "";

async function advance(ms: number) {
  await act(() => vi.advanceTimersByTimeAsync(ms));
  await flush();
}

function fileInput(container: HTMLElement): HTMLInputElement {
  const input = container.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) {
    throw new Error("no file input");
  }
  return input;
}

function changeButton(): HTMLButtonElement {
  return screen.getByRole<HTMLButtonElement>("button", { name: t.details.change });
}

function titleBox(): HTMLTextAreaElement {
  return screen.getByLabelText<HTMLTextAreaElement>(/Tiêu đề/);
}

async function choose(container: HTMLElement, file: File) {
  fireEvent.change(fileInput(container), { target: { files: [file] } });
  await flush();
}

async function post(container: HTMLElement, title = "Chiều Hà Nội cuối thu") {
  await choose(container, clip());
  fireEvent.change(screen.getByLabelText(/Tiêu đề/), { target: { value: title } });
  fireEvent.click(screen.getByRole("button", { name: t.details.submit }));
  await flush();
}

describe("upload screen: choosing a file", () => {
  it("starts on step 1 with the limits", () => {
    renderScreen();
    expect(screen.getByRole("heading", { name: t.title })).toBeTruthy();
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
    expect(screen.getByRole("button", { name: t.pick.button })).toBeTruthy();
  });

  it("refuses a file that is not a video (M22)", async () => {
    const { container } = renderScreen();
    await choose(container, fakeFile("bao-cao-quy-3.pdf", "application/pdf", 1000));
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain(t.fileError.notVideo.title);
    expect(alert.textContent).toContain("“bao-cao-quy-3.pdf” không phải file video.");
    expect(readDuration).not.toHaveBeenCalled();
  });

  it("refuses a file over 500 MB with its size (M21)", async () => {
    const { container } = renderScreen();
    await choose(container, fakeFile("vlog-da-lat.mp4", "video/mp4", 742 * 1024 * 1024));
    expect(screen.getByRole("alert").textContent).toContain("“vlog-da-lat.mp4” nặng 742 MB. Chọn video tối đa 500 MB.");
  });

  it("refuses an empty file", async () => {
    const { container } = renderScreen();
    await choose(container, fakeFile("clip.mp4", "video/mp4", 0));
    expect(screen.getByRole("alert").textContent).toContain(t.fileError.empty.title);
  });

  it("refuses a video longer than 3 minutes (M23)", async () => {
    vi.mocked(readDuration).mockResolvedValue(252);
    const { container } = renderScreen();
    await choose(container, clip());
    expect(screen.getByRole("alert").textContent).toContain("Video dài 4:12. Chọn clip tối đa 3 phút.");
  });

  it("lets a video through when the browser cannot read its duration, and shows the size alone", async () => {
    vi.mocked(readDuration).mockResolvedValue(null);
    const { container } = renderScreen();
    await choose(container, clip());
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    expect(screen.getByText("19,2 MB")).toBeTruthy();
  });

  it("guesses the type of a file without one from its extension and sends it", async () => {
    const bodies = initServer();
    const { container } = renderScreen();
    await choose(container, fakeFile("clip.mov", "", 1000));
    fireEvent.change(screen.getByLabelText(/Tiêu đề/), { target: { value: "Clip" } });
    fireEvent.click(screen.getByRole("button", { name: t.details.submit }));
    await flush();
    expect(bodies).toEqual([{ title: "Clip", size_bytes: 1000, content_type: "video/quicktime" }]);
  });

  it("stops checking when a newer pick is refused while the earlier one's duration is being read", async () => {
    let read: (seconds: number) => void = () => {};
    vi.mocked(readDuration).mockReturnValueOnce(new Promise((resolve) => (read = resolve)));
    const { container } = renderScreen();
    await choose(container, clip());
    expect(screen.getByRole("button", { name: t.pick.checking })).toBeTruthy();

    await choose(container, fakeFile("bao-cao-quy-3.pdf", "application/pdf", 1000));
    expect(screen.getByRole("alert").textContent).toContain(t.fileError.notVideo.title);
    expect(screen.getByRole("button", { name: t.pick.button })).toBeTruthy();

    // The earlier read ends: it was replaced, so it changes nothing.
    read(42);
    await flush();
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
    expect(screen.getByRole("button", { name: t.pick.button })).toBeTruthy();
  });

  it("takes a file dropped on the zone", async () => {
    renderScreen();
    fireEvent.drop(screen.getByTestId("drop-zone"), { dataTransfer: { files: [clip()], types: ["Files"] } });
    await flush();
    expect(screen.getByText("chieu-ho-guom.mp4")).toBeTruthy();
    expect(screen.getByText("19,2 MB · 0:42")).toBeTruthy();
  });
});

describe("upload screen: details", () => {
  it("requires a title and sends nothing without one (M26)", async () => {
    const bodies = initServer();
    const { container } = renderScreen();
    await choose(container, clip());
    fireEvent.change(screen.getByLabelText(/Tiêu đề/), { target: { value: "   " } });
    fireEvent.click(screen.getByRole("button", { name: t.details.submit }));
    await flush();
    expect(screen.getByText(t.details.titleRequired)).toBeTruthy();
    expect(screen.getByLabelText(/Tiêu đề/).getAttribute("aria-invalid")).toBe("true");
    expect(bodies).toEqual([]);
  });

  it("refuses a title over 200 characters", async () => {
    const { container } = renderScreen();
    await choose(container, clip());
    fireEvent.change(screen.getByLabelText(/Tiêu đề/), { target: { value: "a".repeat(201) } });
    fireEvent.click(screen.getByRole("button", { name: t.details.submit }));
    expect(screen.getByText(t.details.titleTooLong)).toBeTruthy();
    expect(screen.getByText("201/200")).toBeTruthy();
  });

  it("goes back to step 1 on Change file", async () => {
    const { container } = renderScreen();
    await choose(container, clip());
    fireEvent.click(screen.getByRole("button", { name: t.details.change }));
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
  });
});

describe("upload screen: uploading", () => {
  it("shows progress, then processing, then READY with a link to the video", async () => {
    const bodies = initServer();
    const polls = processingServer("PROCESSING", "READY");
    const { container } = renderScreen();
    await post(container, "  Chiều Hà Nội cuối thu  ");
    expect(bodies).toEqual([{ title: "Chiều Hà Nội cuối thu", size_bytes: 20_132_659, content_type: "video/mp4" }]);
    expect(screen.getByText("Bước 3/3")).toBeTruthy();

    const xhr = FakeXHR.last();
    expect(xhr.url).toBe(uploadUrl);
    // The request body is a little larger than the file: the form fields go first.
    xhr.progress(0, 20_133_000);
    await advance(1000);
    act(() => xhr.progress(10_066_500, 20_133_000));
    expect(screen.getByText("Đang tải lên (50%)")).toBeTruthy();
    const bar = screen.getByRole("progressbar", { name: t.progress.label });
    expect(bar.getAttribute("aria-valuenow")).toBe("50");
    expect((bar.firstElementChild as HTMLElement).style.width).toBe("50%");
    // About 9,5 MB in about a second (each flush moves the fake clock a little).
    expect(screen.getByText(/^9,6 \/ 19,2 MB · 9,[45] MB\/s · còn khoảng [12] giây$/)).toBeTruthy();
    // The upload's credential is never put on the page.
    expect(container.innerHTML).not.toContain(uploadUrl);
    expect(container.innerHTML).not.toContain("cG9saWN5");

    act(() => xhr.respond(204));
    await flush();
    expect(screen.getByText(t.result.processingTitle)).toBeTruthy();
    expect(screen.getByRole("link", { name: t.result.myVideos }).getAttribute("href")).toBe("/me");

    await advance(2000);
    await advance(3000);
    expect(polls).toHaveLength(2);
    expect(screen.getByText(t.result.readyTitle)).toBeTruthy();
    expect(screen.getByRole("link", { name: t.result.watch }).getAttribute("href")).toBe(`/v/${videoId}`);

    fireEvent.click(screen.getByRole("button", { name: t.result.another }));
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
    expect(uploadStore.list()).toEqual([]);
  });

  it("shows FAILED processing with Choose another file (M32)", async () => {
    initServer();
    processingServer("FAILED");
    const { container } = renderScreen();
    await post(container);
    act(() => FakeXHR.last().respond(204));
    await flush();
    await advance(2000);
    expect(screen.getByText(t.result.failedTitle)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: t.result.pickAnother }));
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
  });

  it("stops polling when the page goes away", async () => {
    initServer();
    const polls = processingServer("PROCESSING");
    const { container, unmount } = renderScreen();
    await post(container);
    act(() => FakeXHR.last().respond(204));
    await flush();
    await advance(2000);
    expect(polls).toHaveLength(1);
    unmount();
    await advance(120_000);
    expect(polls).toHaveLength(1);
  });

  it("shows the automatic retries (M29), then Retry by hand once they are used up", async () => {
    // The backoff is a random wait up to 1 s, 2 s, then 4 s. Pinned halfway, the first one is still running when the
    // alert is read; a wait under the few milliseconds a flush moves the clock (about one run in a hundred) would
    // already be over, and the next attempt would have replaced the alert.
    vi.spyOn(Math, "random").mockReturnValue(0.5);
    initServer();
    const { container } = renderScreen();
    await post(container);
    await flushUntil(() => FakeXHR.instances.length === 1, "the first attempt");
    act(() => FakeXHR.last().fail());
    await flushUntil(() => alertText().includes("lần 1/3"), "the first retry");
    expect(screen.getByRole("alert").textContent).toContain("Đang tự thử lại… lần 1/3");
    expect(screen.getByText(t.progress.waiting)).toBeTruthy();
    for (let retry = 1; retry <= 3; retry++) {
      await advance(8000);
      await flushUntil(() => FakeXHR.instances.length === retry + 1, `attempt ${retry + 1}`);
      act(() => FakeXHR.last().fail());
      await flushUntil(
        () => alertText().includes(retry < 3 ? `lần ${retry + 1}/3` : t.failure.sendFailed.title),
        `the alert after attempt ${retry + 1}`,
      );
    }
    expect(FakeXHR.instances).toHaveLength(4);
    expect(screen.getByRole("alert").textContent).toContain(t.failure.sendFailed.title);
    fireEvent.click(screen.getByRole("button", { name: t.progress.retry }));
    await flushUntil(() => FakeXHR.instances.length === 5, "the attempt Retry starts");
    expect(FakeXHR.instances).toHaveLength(5);
    expect(screen.getByText("Đang tải lên (0%)")).toBeTruthy();
  });

  it("says the connection is lost while offline", async () => {
    initServer();
    const { container } = renderScreen();
    await post(container);
    vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    act(() => FakeXHR.last().fail());
    await advance(1000);
    expect(screen.getByRole("alert").textContent).toContain(t.progress.offline.title);
  });

  it("tells about a new upload session after the storage refused an expired form", async () => {
    initServer();
    const { container } = renderScreen();
    await post(container);
    act(() => FakeXHR.last().respond(403));
    await flush();
    expect(FakeXHR.instances).toHaveLength(2);
    expect(screen.getByRole("alert").textContent).toContain(t.progress.renewed.title);
  });

  it("cancel aborts the upload and goes back to the details, saying the slot stays taken", async () => {
    initServer();
    const { container } = renderScreen();
    await post(container);
    fireEvent.click(screen.getByRole("button", { name: t.progress.cancel }));
    await flush();
    expect(FakeXHR.last().aborted).toBe(true);
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    expect(screen.getByRole("alert").textContent).toContain(t.cancelled.body);
    expect((screen.getByLabelText(/Tiêu đề/) as HTMLTextAreaElement).value).toBe("Chiều Hà Nội cuối thu");
  });
});

describe("upload screen: refusals", () => {
  // No form yet means no video yet: the details step stays, its button busy, instead of a paused upload of 0 MB.
  it("stays on the details while a rate limited form request waits for its Retry-After", async () => {
    const bodies = initServer();
    server.use(
      http.post(
        "*/api/videos",
        () =>
          HttpResponse.json(
            { type: "about:blank", title: "", status: 429, detail: "", code: "RATE_LIMITED" },
            { status: 429, headers: { "Content-Type": "application/problem+json", "Retry-After": "5" } },
          ),
        { once: true },
      ),
    );
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    expect(screen.getByRole("button", { name: t.details.submitting })).toBeTruthy();
    expect(screen.queryByText(t.progress.waiting)).toBeNull();
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain(t.failure.rateLimited.title);
    expect(alert.textContent).toContain("Đang tự thử lại… lần 1/3");
    expect(changeButton().disabled).toBe(false);
    expect(titleBox().readOnly).toBe(true);
    expect(FakeXHR.instances).toHaveLength(0);

    await advance(5000);
    expect(bodies).toHaveLength(1);
    expect(FakeXHR.instances).toHaveLength(1);
    expect(screen.getByText("Bước 3/3")).toBeTruthy();
  });

  it("stays on the details while offline before the form is asked for", async () => {
    initServer();
    const online = vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    expect(screen.getByRole("button", { name: t.details.submitting })).toBeTruthy();
    expect(screen.queryByText(t.progress.waiting)).toBeNull();
    expect(screen.getByRole("alert").textContent).toContain(t.progress.offline.title);
    expect(changeButton().disabled).toBe(false);
    expect(titleBox().readOnly).toBe(true);

    online.mockReturnValue(true);
    act(() => {
      window.dispatchEvent(new Event("online"));
    });
    await flush();
    expect(FakeXHR.instances).toHaveLength(1);
    expect(screen.getByText("Bước 3/3")).toBeTruthy();
  });

  it("Change file during an offline wait before the form drops the wait, and no request goes out later", async () => {
    const bodies = initServer();
    const online = vi.spyOn(navigator, "onLine", "get").mockReturnValue(false);
    const { container } = renderScreen();
    await post(container);
    fireEvent.click(changeButton());
    await flush();
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
    expect(uploadStore.list()).toEqual([]);

    online.mockReturnValue(true);
    act(() => {
      window.dispatchEvent(new Event("online"));
    });
    await flush();
    expect(bodies).toEqual([]);
    expect(FakeXHR.instances).toHaveLength(0);
  });

  it("Change file during a Retry-After wait before the form drops the wait, and the request is not sent again", async () => {
    const bodies = initServer();
    server.use(
      http.post(
        "*/api/videos",
        () =>
          HttpResponse.json(
            { type: "about:blank", title: "", status: 429, detail: "", code: "RATE_LIMITED" },
            { status: 429, headers: { "Content-Type": "application/problem+json", "Retry-After": "5" } },
          ),
        { once: true },
      ),
    );
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByRole("alert").textContent).toContain(t.failure.rateLimited.title);
    fireEvent.click(changeButton());
    await flush();
    expect(screen.getByText("Bước 1/3")).toBeTruthy();
    expect(uploadStore.list()).toEqual([]);

    await advance(60_000);
    expect(bodies).toEqual([]);
    expect(FakeXHR.instances).toHaveLength(0);
  });

  it("locks Change file and the title while the form request is on its way: it may create a video", async () => {
    let answer: () => void = () => {};
    initServer();
    server.use(
      http.post(
        "*/api/videos",
        async () => {
          await new Promise<void>((resolve) => (answer = resolve));
          return problem(429, "TOO_MANY_UPLOADS");
        },
        { once: true },
      ),
    );
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByRole("button", { name: t.details.submitting })).toBeTruthy();
    expect(changeButton().disabled).toBe(true);
    expect(titleBox().readOnly).toBe(true);

    answer();
    await flush();
    expect(screen.getByRole("alert").textContent).toContain(t.failure.tooManyUploads.title);
    expect(changeButton().disabled).toBe(false);
    expect(titleBox().readOnly).toBe(false);
  });

  it("TOO_MANY_UPLOADS keeps the file and title and points to My videos (M24)", async () => {
    initServer(() => problem(429, "TOO_MANY_UPLOADS"));
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByText("Bước 2/3")).toBeTruthy();
    const alert = screen.getByRole("alert");
    expect(alert.textContent).toContain(t.failure.tooManyUploads.title);
    expect(screen.getByRole("link", { name: t.failure.tooManyUploads.link }).getAttribute("href")).toBe("/me");
    expect((screen.getByLabelText(/Tiêu đề/) as HTMLTextAreaElement).value).toBe("Chiều Hà Nội cuối thu");
    expect(FakeXHR.instances).toHaveLength(0);
  });

  it("a refused session sends the user to log in, back to /upload", async () => {
    initServer(() => problem(401, "UNAUTHENTICATED"));
    const { container } = renderScreen();
    await post(container);
    expect(router.replace).toHaveBeenCalledWith("/login?next=%2Fupload");
  });

  it("a refused session while polling sends the user to log in", async () => {
    initServer();
    processingServer(() => problem(401, "UNAUTHENTICATED"));
    const { container } = renderScreen();
    await post(container);
    act(() => FakeXHR.last().respond(204));
    await flush();
    await advance(2000);
    expect(router.replace).toHaveBeenCalledWith("/login?next=%2Fupload");
  });

  it("an upload_url on another origin is refused before any byte is sent", async () => {
    initServer(() =>
      HttpResponse.json(
        {
          video_id: videoId,
          upload_url: "https://evil.example/u",
          form_fields: {},
          expires_at: "2026-10-22T08:15:00Z",
        },
        { status: 201 },
      ),
    );
    const { container } = renderScreen();
    await post(container);
    expect(screen.getByRole("alert").textContent).toContain(t.failure.badOrigin.title);
    expect(FakeXHR.instances).toHaveLength(0);
  });
});
