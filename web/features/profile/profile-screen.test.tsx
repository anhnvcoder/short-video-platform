import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { useRouter } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";
import { messagesFor } from "@/i18n/messages";
import { formatCompact } from "@/lib/format";
import { server } from "@/lib/test/msw-server";
import type { ProfileVideo, ProfileVideoPage, ShownProfile } from "./api";
import { ProfileScreen } from "./profile-screen";

vi.mock("next/navigation", () => ({ useRouter: vi.fn() }));

const mediaOrigin = "http://127.0.0.1:9000";
const authorId = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const id = (n: number) => `0192f0c1-0000-7000-8000-${String(n).padStart(12, "0")}`;
const router = { replace: vi.fn(), push: vi.fn(), back: vi.fn() };
const t = messagesFor("vi").profile;

const minhAnh: ShownProfile = { userId: authorId, handle: "minhanh", displayName: "Minh Anh", followedByMe: false };

function ready(n: number, extra: Partial<ProfileVideo> = {}): ProfileVideo {
  return {
    video_id: id(n),
    title: `Video ${n}`,
    status: "READY",
    created_at: "2026-10-19T08:00:00Z",
    duration_ms: 58_000,
    published_at: "2026-10-19T08:00:00Z",
    thumbnail_url: `${mediaOrigin}/thumbs/${n}.jpg`,
    view_count: 8300,
    ...extra,
  };
}

function renderProfile({
  profile = minhAnh,
  initialPage = { items: [ready(1)], next_cursor: "" },
}: { profile?: ShownProfile; initialPage?: ProfileVideoPage } = {}) {
  return render(
    <NextIntlClientProvider locale="vi" messages={{ profile: messagesFor("vi").profile }}>
      <QueryClientProvider client={new QueryClient()}>
        <ProfileScreen profile={profile} initialPage={initialPage} mediaOrigin={mediaOrigin} />
      </QueryClientProvider>
    </NextIntlClientProvider>,
  );
}

// PUT and DELETE /api/me/following/<id>: each call gets the next answer, the last one from then on.
function followServer(...answers: (() => Response)[]) {
  const calls: string[] = [];
  const handler = ({ request }: { request: Request }) => {
    calls.push(`${request.method} ${new URL(request.url).pathname}`);
    const answer =
      (answers.length > 1 ? answers.shift() : answers[0]) ?? (() => new HttpResponse(null, { status: 204 }));
    return answer();
  };
  server.use(http.put("*/api/me/following/:id", handler), http.delete("*/api/me/following/:id", handler));
  return calls;
}

// jsdom has no Clipboard API.
function stubClipboard(writeText: (text: string) => Promise<void>) {
  Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
  onTestFinished(() => {
    Reflect.deleteProperty(navigator, "clipboard");
  });
}

const followButton = () => screen.getByRole("button", { name: /^(Theo dõi|Đang theo dõi)$/ });

beforeEach(() => {
  vi.mocked(useRouter).mockReturnValue(router as unknown as ReturnType<typeof useRouter>);
  router.replace.mockReset();
  router.back.mockReset();
  router.push.mockReset();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("ProfileScreen", () => {
  it("shows the name and handle as text, and the videos as links with views and length", () => {
    renderProfile({
      profile: { ...minhAnh, displayName: "<script>alert(1)</script> Minh 👩‍👩‍👧" },
      initialPage: {
        items: [ready(1), ready(2, { view_count: undefined, thumbnail_url: "https://evil.example/t.jpg" })],
        next_cursor: "",
      },
    });
    expect(screen.getByRole("heading", { level: 1 }).textContent).toBe("<script>alert(1)</script> Minh 👩‍👩‍👧");
    expect(document.querySelector("script")).toBeNull();
    expect(screen.getAllByText("@minhanh").length).toBeGreaterThan(0);

    const grid = screen.getByRole("list", { name: "Video của <script>alert(1)</script> Minh 👩‍👩‍👧" });
    const [first, second] = within(grid).getAllByRole("link");
    expect(first!.getAttribute("href")).toBe(`/v/${id(1)}`);
    // Named by its content, title first, so the views and length it shows are in the name too (WCAG 2.5.3).
    expect(first!.hasAttribute("aria-label")).toBe(false);
    // Testing Library trims the text of each part before joining them, which browsers do not: compare without spaces.
    const named = (expected: string) => (name: string) => name.replace(/\s/g, "") === expected.replace(/\s/g, "");
    expect(within(grid).getByRole("link", { name: named(`Video 1, ${formatCompact(8300, "vi")}, 0:58`) })).toBe(first);
    expect(within(grid).getByRole("link", { name: named("Video 2, 0:58") })).toBe(second);
    expect(first!.querySelector("img")?.getAttribute("src")).toBe(`${mediaOrigin}/thumbs/1.jpg`);
    expect(first!.textContent).toBe(`Video 1, ${formatCompact(8300, "vi")}, 0:58`);
    // No views without stats; no thumbnail off the media origin.
    expect(second!.textContent).toBe("Video 2, 0:58");
    expect(second!.querySelector("img")).toBeNull();
  });

  it("shows only READY videos", () => {
    renderProfile({
      initialPage: { items: [ready(1), { ...ready(2), status: "PROCESSING" }], next_cursor: "" },
    });
    expect(within(screen.getByRole("list")).getAllByRole("link")).toHaveLength(1);
  });

  it("says there is no video yet when the author has none READY (M37)", () => {
    renderProfile({ initialPage: { items: [], next_cursor: "" } });
    expect(screen.getByText(t.other.empty.title)).toBeTruthy();
    expect(screen.getByText(t.other.empty.body.replace("{name}", "Minh Anh"))).toBeTruthy();
  });

  it("loads the next page of videos", async () => {
    const calls: URL[] = [];
    server.use(
      http.get(`*/api/users/${authorId}/videos`, ({ request }) => {
        calls.push(new URL(request.url));
        return HttpResponse.json({
          items: [{ ...ready(2), author_id: authorId, stats: { view_count: 1, like_count: 0, liked_by_me: false } }],
          next_cursor: "",
        });
      }),
    );
    renderProfile({ initialPage: { items: [ready(1)], next_cursor: "abc" } });
    fireEvent.click(screen.getByRole("button", { name: t.loadMore }));
    await waitFor(() => expect(within(screen.getByRole("list")).getAllByRole("link")).toHaveLength(2));
    expect(Object.fromEntries(calls[0]!.searchParams)).toEqual({ cursor: "abc", page_size: "18" });
  });

  it("follows and unfollows through the API, with aria-pressed from followed_by_me", async () => {
    const calls = followServer();
    renderProfile();
    expect(followButton().textContent).toBe(t.other.follow);
    expect(followButton().getAttribute("aria-pressed")).toBe("false");

    await act(async () => fireEvent.click(followButton()));
    await waitFor(() => expect(followButton().getAttribute("aria-pressed")).toBe("true"));
    expect(followButton().textContent).toBe(t.other.following);

    await act(async () => fireEvent.click(followButton()));
    await waitFor(() => expect(followButton().getAttribute("aria-pressed")).toBe("false"));
    expect(calls).toEqual([`PUT /api/me/following/${authorId}`, `DELETE /api/me/following/${authorId}`]);
  });

  it("starts as followed when the gateway says so", () => {
    renderProfile({ profile: { ...minhAnh, followedByMe: true } });
    expect(followButton().getAttribute("aria-pressed")).toBe("true");
    expect(followButton().textContent).toBe(t.other.following);
  });

  it("keeps the state and says so when following fails (503)", async () => {
    followServer(() => HttpResponse.json({ code: "UNAVAILABLE" }, { status: 503 }));
    renderProfile();
    await act(async () => fireEvent.click(followButton()));
    expect(await screen.findByText(t.toast.followFailed.replace("{name}", "Minh Anh"))).toBeTruthy();
    expect(followButton().getAttribute("aria-pressed")).toBe("false");
    expect((followButton() as HTMLButtonElement).disabled).toBe(false);
  });

  it("waits for the Retry-After of a 429 before the button works again", async () => {
    followServer(() => HttpResponse.json({ code: "RATE_LIMITED" }, { status: 429, headers: { "Retry-After": "30" } }));
    renderProfile({ profile: { ...minhAnh, followedByMe: true } });
    await act(async () => fireEvent.click(followButton()));
    expect(await screen.findByText(t.toast.rateLimited)).toBeTruthy();
    expect(followButton().getAttribute("aria-pressed")).toBe("true");
    expect((followButton() as HTMLButtonElement).disabled).toBe(true);
  });

  it("sends the user to log in and back when the session is refused", async () => {
    followServer(() => HttpResponse.json({ code: "UNAUTHENTICATED" }, { status: 401 }));
    renderProfile();
    await act(async () => fireEvent.click(followButton()));
    await waitFor(() => expect(router.replace).toHaveBeenCalledWith(`/login?next=${encodeURIComponent("/u/minhanh")}`));
  });

  it("copies the profile link of this origin and says so", async () => {
    const writeText = vi.fn(async () => {});
    stubClipboard(writeText);
    renderProfile();
    // One copy button per layout (phone bar, wide row).
    await act(async () => fireEvent.click(screen.getAllByRole("button", { name: t.other.copyLink })[0]!));
    expect(writeText).toHaveBeenCalledWith(`${window.location.origin}/u/minhanh`);
    expect(await screen.findByText(t.toast.linkCopied)).toBeTruthy();
  });

  it("says when the link could not be copied", async () => {
    stubClipboard(async () => Promise.reject(new Error("denied")));
    renderProfile();
    await act(async () => fireEvent.click(screen.getAllByRole("button", { name: t.other.copyLink })[0]!));
    expect(await screen.findByText(t.toast.copyFailed)).toBeTruthy();
  });

  it("goes back, or home when the profile was opened from outside", () => {
    renderProfile();
    vi.spyOn(window.history, "length", "get").mockReturnValue(1);
    fireEvent.click(screen.getByRole("button", { name: t.other.back }));
    expect(router.push).toHaveBeenCalledWith("/");
    vi.spyOn(window.history, "length", "get").mockReturnValue(3);
    fireEvent.click(screen.getByRole("button", { name: t.other.back }));
    expect(router.back).toHaveBeenCalledTimes(1);
  });
});
