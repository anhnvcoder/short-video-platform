import { describe, expect, it, vi } from "vitest";
import { UploadRoute } from "@/features/upload/upload-route";
import UploadPage, { generateMetadata } from "./page";

vi.mock("next-intl/server", () => ({ getTranslations: async () => (key: string) => `upload.${key}` }));

describe("upload page", () => {
  it("is titled from the upload namespace and renders the upload route", async () => {
    expect(await generateMetadata()).toEqual({ title: "upload.metaTitle" });
    expect(UploadPage().type).toBe(UploadRoute);
  });
});
