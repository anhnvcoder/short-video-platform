import { describe, expect, it } from "vitest";
import { cleanPage, shareUrl, type FeedItem } from "./api";

const authorId = "0192f0c1-7a3e-7c4b-9d2e-000000000002";
const item: FeedItem = {
  video_id: "0192f0c1-0000-7000-8000-000000000001",
  author_id: authorId,
  title: "first",
  duration_ms: 42_000,
  playlist_url: "http://127.0.0.1:9000/media/hls/1/master.m3u8",
  thumbnail_url: "http://127.0.0.1:9000/media/thumbs/1.jpg",
  published_at: "2026-10-20T08:00:00Z",
  author: { user_id: authorId, handle: "minhanh", display_name: "Minh Anh" },
  stats: { view_count: 2, like_count: 1, liked_by_me: true },
};

describe("cleanPage", () => {
  it("keeps the author and every field of the schema", () => {
    expect(cleanPage({ items: [item], next_cursor: "c1" })).toEqual({ items: [item], next_cursor: "c1" });
  });

  it("keeps only the fields of the schema", () => {
    const extra = {
      ...item,
      email: "a@b.c",
      author: { ...item.author, email: "a@b.c" },
      stats: { ...item.stats, secret: 1 },
    } as FeedItem;
    const page = { items: [extra], next_cursor: "", debug: true } as Parameters<typeof cleanPage>[0];
    expect(cleanPage(page)).toEqual({ items: [item], next_cursor: "" });
    expect(JSON.stringify(cleanPage(page))).not.toContain("a@b.c");
  });

  it.each([
    ["a handle that is not in the stored form", { ...item.author!, handle: "../evil" }],
    ["an upper-case handle", { ...item.author!, handle: "MinhAnh" }],
    ["an empty display name", { ...item.author!, display_name: "" }],
    ["someone else's profile", { ...item.author!, user_id: "0192f0c1-7a3e-7c4b-9d2e-000000000009" }],
  ])("drops %s and keeps the video", (_, author) => {
    const [cleaned] = cleanPage({ items: [{ ...item, author }], next_cursor: "" }).items;
    expect(cleaned).toEqual({ ...item, author: undefined });
    expect(cleaned && "author" in cleaned).toBe(false);
  });

  it("keeps an item without author or stats as it is", () => {
    const bare: FeedItem = { ...item };
    delete bare.author;
    delete bare.stats;
    expect(cleanPage({ items: [bare], next_cursor: "" }).items).toEqual([bare]);
  });

  it("drops items whose ids are not canonical UUIDs", () => {
    const page = { items: [item, { ...item, video_id: "../x" }, { ...item, author_id: "A" }], next_cursor: "" };
    expect(cleanPage(page).items).toEqual([item]);
  });
});

describe("shareUrl", () => {
  it("is /v/<id> on the given origin", () => {
    expect(shareUrl("http://localhost:3001", item.video_id)).toBe(`http://localhost:3001/v/${item.video_id}`);
  });
});
