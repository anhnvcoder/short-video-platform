import { describe, expect, it } from "vitest";
import type { components } from "@/gen/api";
import { cleanVideoPage, isHandle, lowerHandle } from "./api";

type Video = components["schemas"]["Video"];

const authorId = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const videoId = "0192f0c1-0000-7000-8000-000000000001";

const base: Video = {
  video_id: videoId,
  author_id: authorId,
  title: "Chiều",
  status: "READY",
  created_at: "2026-10-20T08:00:00Z",
  duration_ms: 58_000,
  published_at: "2026-10-20T08:01:00Z",
  playlist_url: "http://127.0.0.1:9000/v/master.m3u8",
  thumbnail_url: "http://127.0.0.1:9000/v/thumb.jpg",
  author: { user_id: authorId, handle: "minhanh", display_name: "Minh Anh" },
  stats: { view_count: 8300, like_count: 12, liked_by_me: true },
};

describe("cleanVideoPage", () => {
  it("keeps only the fields the lists show", () => {
    expect(cleanVideoPage({ items: [base], next_cursor: "c" }, authorId)).toEqual({
      items: [
        {
          video_id: videoId,
          title: "Chiều",
          status: "READY",
          created_at: "2026-10-20T08:00:00Z",
          duration_ms: 58_000,
          published_at: "2026-10-20T08:01:00Z",
          thumbnail_url: "http://127.0.0.1:9000/v/thumb.jpg",
          view_count: 8300,
        },
      ],
      next_cursor: "c",
    });
  });

  it("keeps a video that is not READY with its status only", () => {
    const processing: Video = {
      video_id: videoId,
      author_id: authorId,
      title: "",
      status: "PROCESSING",
      created_at: "x",
    };
    expect(cleanVideoPage({ items: [processing], next_cursor: "" }, authorId).items).toEqual([
      { video_id: videoId, title: "", status: "PROCESSING", created_at: "x" },
    ]);
  });

  it.each<[string, Partial<Video>]>([
    ["an id that is not a canonical UUID", { video_id: videoId.toUpperCase() }],
    ["a path in the id", { video_id: "../../me" }],
    ["another author", { author_id: "0192f0c1-7a3e-7c4b-9d2e-000000000003" }],
    ["an unknown status", { status: "DELETED" as Video["status"] }],
  ])("drops a video with %s", (_name, change) => {
    expect(cleanVideoPage({ items: [{ ...base, ...change }], next_cursor: "" }, authorId).items).toEqual([]);
  });
});

describe("handles", () => {
  it.each([
    ["minhanh", true],
    ["u_23456789abcd", true],
    ["a".repeat(30), true],
    ["a".repeat(31), false],
    ["ab", false],
    ["_bob", false],
    ["MinhAnh", false],
    ["bób", false],
    ["min/hanh", false],
  ])("%j is a handle: %s", (value, expected) => {
    expect(isHandle(value)).toBe(expected);
  });

  it("lowers A-Z only, so the Kelvin sign stays and fails the check", () => {
    expect(lowerHandle("MinhAnh")).toBe("minhanh");
    expect(lowerHandle("Kelvin")).toBe("Kelvin");
    expect(isHandle(lowerHandle("Kelvin"))).toBe(false);
  });
});
