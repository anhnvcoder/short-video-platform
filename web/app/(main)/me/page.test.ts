import { describe, expect, it, vi } from "vitest";
import { MyVideosRoute } from "@/features/profile/my-videos-route";
import MyVideosPage, { generateMetadata } from "./page";

vi.mock("next-intl/server", () => ({ getTranslations: async () => (key: string) => `profile.${key}` }));
vi.mock("@/features/profile/my-videos-route", () => ({ MyVideosRoute: () => null }));

describe("/me page", () => {
  it("is titled from the profile namespace and renders My videos", async () => {
    expect(await generateMetadata()).toEqual({ title: "profile.my.metaTitle" });
    expect(MyVideosPage().type).toBe(MyVideosRoute);
  });
});
