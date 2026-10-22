import type { ReactElement } from "react";
import { getURLFromRedirectError } from "next/dist/client/components/redirect";
import { isRedirectError } from "next/dist/client/components/redirect-error";
import { createTranslator } from "next-intl";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { rateLimitWait } from "@/components/shell/route-error";
import { messagesFor } from "@/i18n/messages";
import type { ProfilePage as LoadedPage } from "@/server/profile-page";
import { testEnv } from "@/server/testing/bff";

const loader = vi.hoisted(() => ({ load: vi.fn() }));

vi.mock("@/server/profile-page", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/server/profile-page")>()),
  loadProfilePage: loader.load,
}));
vi.mock("@/server/env", () => ({ serverEnv: () => testEnv }));
vi.mock("next-intl/server", () => ({
  getMessages: async () => messagesFor("vi"),
  getTranslations: async (namespace: string) =>
    createTranslator({ locale: "vi", messages: messagesFor("vi"), namespace: namespace as "profile" }),
}));

const { default: ProfilePage, generateMetadata } = await import("./page");

const authorId = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const shown: LoadedPage = {
  kind: "profile",
  profile: { userId: authorId, handle: "minhanh", displayName: "Minh Anh", followedByMe: true },
  videos: { page: { items: [], next_cursor: "" }, fetchedAt: 1 },
};

const params = (handle: string) => ({ params: Promise.resolve({ handle }) });
const t = messagesFor("vi").profile;

async function thrown(run: Promise<unknown>): Promise<unknown> {
  return run.then(
    () => undefined,
    (error: unknown) => error,
  );
}

const digestOf = (error: unknown) => (error as { digest?: string } | undefined)?.digest;
const notFoundDigest = "NEXT_HTTP_ERROR_FALLBACK;404";

function redirectTarget(error: unknown): string | null {
  return isRedirectError(error) ? getURLFromRedirectError(error) : null;
}

beforeEach(() => {
  loader.load.mockReset();
});

describe("generateMetadata of /u/[handle]", () => {
  it("is the handle, without loading anything", async () => {
    expect(await generateMetadata(params("MinhAnh"))).toEqual({ title: "@minhanh" });
    expect(loader.load).not.toHaveBeenCalled();
  });

  it("is the profile's 404 title for what cannot be a handle", async () => {
    expect(await generateMetadata(params("a b"))).toEqual({ title: t.notFound.title });
  });
});

describe("/u/[handle] page", () => {
  it.each(["ab", "_bob", "b%C3%B3b", "bób", "..", "a".repeat(31), "u-x"])(
    "is the profile's 404 for %j, without loading anything",
    async (handle) => {
      expect(digestOf(await thrown(ProfilePage(params(handle))))).toBe(notFoundDigest);
      expect(loader.load).not.toHaveBeenCalled();
    },
  );

  it("lowers A-Z in the path with a redirect, without loading anything", async () => {
    expect(redirectTarget(await thrown(ProfilePage(params("MinhAnh"))))).toBe("/u/minhanh");
    expect(loader.load).not.toHaveBeenCalled();
  });

  it("is the profile's 404 when no user has the handle", async () => {
    loader.load.mockResolvedValue({ kind: "not-found" });
    expect(digestOf(await thrown(ProfilePage(params("minhanh"))))).toBe(notFoundDigest);
    expect(loader.load).toHaveBeenCalledWith("minhanh");
  });

  it("sends the viewer's own handle to /me", async () => {
    loader.load.mockResolvedValue({ kind: "self" });
    expect(redirectTarget(await thrown(ProfilePage(params("lanphuong"))))).toBe("/me");
  });

  it("shows the rate limit page counting down the gateway's Retry-After", async () => {
    loader.load.mockResolvedValue({ kind: "rate-limited", retryAfterSeconds: 30 });
    expect(rateLimitWait(await thrown(ProfilePage(params("minhanh"))))).toBe(30);
  });

  it("shows the generic error page when the profile cannot be loaded", async () => {
    loader.load.mockResolvedValue({ kind: "unavailable" });
    const error = await thrown(ProfilePage(params("minhanh")));
    expect(error).toBeInstanceOf(Error);
    expect(rateLimitWait(error)).toBeNull();
    expect(isRedirectError(error)).toBe(false);
  });

  it("hands the screen the profile, the first page and the media origin, with the profile messages only", async () => {
    loader.load.mockResolvedValue(shown);
    const element = (await ProfilePage(params("minhanh"))) as ReactElement<{
      messages: Record<string, unknown>;
      children: ReactElement<Record<string, unknown>>;
    }>;
    expect(Object.keys(element.props.messages)).toEqual(["profile"]);
    expect(element.props.children.props).toEqual({
      profile: shown.profile,
      initialPage: { items: [], next_cursor: "" },
      initialRetryAfterSeconds: undefined,
      mediaOrigin: testEnv.mediaOrigin,
    });
    expect(JSON.stringify(element.props.children.props)).not.toMatch(/token|eyJ/i);
  });
});
