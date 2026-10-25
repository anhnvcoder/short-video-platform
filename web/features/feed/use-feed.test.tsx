import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { StrictMode, type ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { server } from "@/lib/test/msw-server";
import type { FeedKind, FeedPage } from "./api";
import { useFeed } from "./use-feed";

const serverPage: FeedPage = { items: [], next_cursor: "" };
const newerPage: FeedPage = { items: [], next_cursor: "newer" };

// Counts the client's requests for the first page of a feed.
function firstPageServer(kind: FeedKind = "explore") {
  const calls: string[] = [];
  server.use(
    http.get(`*/api/feed/${kind}`, () => {
      calls.push(kind);
      return HttpResponse.json(newerPage);
    }),
  );
  return calls;
}

// The tab's module state is kept across the tests of this file: every test names its pages with stamps of its own.
let stamps = 0;
const stamp = (offsetMs = 0) => Date.now() + offsetMs + ++stamps;

// One visit to a feed screen with the page the server (or the router's replay) handed over. A visit gets a cache of its
// own unless it is given the one of the visit before.
function visit(
  fetchedAt: number | undefined,
  {
    kind = "explore",
    strict = false,
    client = new QueryClient(),
  }: { kind?: FeedKind; strict?: boolean; client?: QueryClient } = {},
) {
  const wrapper = ({ children }: { children: ReactNode }) => {
    const tree = <QueryClientProvider client={client}>{children}</QueryClientProvider>;
    return strict ? <StrictMode>{tree}</StrictMode> : tree;
  };
  return renderHook(() => useFeed(kind, serverPage, fetchedAt, true), { wrapper });
}

// No request went out: the effects and React Query's timers have had their turn.
async function noRequest(calls: string[]) {
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(calls).toEqual([]);
}

// Visits a screen and leaves it again; true when the mount asked for the first page again (a replay).
function refetchedOnVisit(fetchedAt: number | undefined, kind: FeedKind = "explore"): boolean {
  const { result, unmount } = visit(fetchedAt, { kind });
  const fetching = result.current.isFetching;
  unmount();
  return fetching;
}

describe("useFeed", () => {
  it("a page from a new server render is shown as it is, without a request", async () => {
    const calls = firstPageServer();
    const { result } = visit(stamp());
    expect(result.current.data?.pages).toEqual([serverPage]);
    expect(result.current.isFetching).toBe(false);
    await noRequest(calls);
  });

  it("the same page shown again (Back right after the visit) is fetched again and replaced", async () => {
    const calls = firstPageServer();
    const fetchedAt = stamp();
    visit(fetchedAt).unmount();
    await noRequest(calls);

    const { result } = visit(fetchedAt);
    // The replayed page shows until the newer one arrives.
    expect(result.current.data?.pages).toEqual([serverPage]);
    expect(result.current.isFetching).toBe(true);
    await waitFor(() => expect(result.current.data?.pages).toEqual([newerPage]));
    expect(calls).toEqual(["explore"]);
  });

  // Back can land before React Query's timer has dropped the feed the screen left (WebKit, a few ms after the switch):
  // the new screen then reads that feed, fetched at the first visit and still fresh, and the replayed page's stamp
  // alone has to bring the request.
  it("Back before the left feed is dropped from the cache: the replayed page is fetched again all the same", async () => {
    const calls = firstPageServer();
    const fetchedAt = stamp();
    const client = new QueryClient();
    visit(fetchedAt, { client }).unmount();
    expect(client.getQueryCache().find({ queryKey: ["feed", "explore"] })).toBeDefined();

    const { result } = visit(fetchedAt, { client });
    expect(result.current.isFetching).toBe(true);
    await waitFor(() => expect(result.current.data?.pages).toEqual([newerPage]));
    expect(calls).toEqual(["explore"]);
  });

  it.each([
    ["two minutes behind", -120_000],
    ["two minutes ahead", 120_000],
  ])("a server clock %s changes nothing: new page, no request; replayed page, one request", async (_, offset) => {
    const calls = firstPageServer();
    const fetchedAt = stamp(offset);
    visit(fetchedAt).unmount();
    await noRequest(calls);

    const { result } = visit(fetchedAt);
    await waitFor(() => expect(result.current.data?.pages).toEqual([newerPage]));
    expect(calls).toEqual(["explore"]);
  });

  it("StrictMode's second render and effect run do not take a new page for a replay", async () => {
    const calls = firstPageServer();
    const fetchedAt = stamp();
    const { unmount } = visit(fetchedAt, { strict: true });
    await noRequest(calls);
    unmount();

    const { result } = visit(fetchedAt, { strict: true });
    await waitFor(() => expect(result.current.data?.pages).toEqual([newerPage]));
    expect(calls).toEqual(["explore"]);
  });

  it("a page of one feed is not a replay of the other feed's page with the same stamp", () => {
    firstPageServer("explore");
    firstPageServer("following");
    const fetchedAt = stamp();
    expect(refetchedOnVisit(fetchedAt, "explore")).toBe(false);
    expect(refetchedOnVisit(fetchedAt, "following")).toBe(false);
  });

  it("remembers the last 50 pages only", () => {
    firstPageServer();
    const oldest = stamp();
    expect(refetchedOnVisit(oldest)).toBe(false);
    const later = Array.from({ length: 50 }, () => stamp());
    for (const fetchedAt of later) {
      expect(refetchedOnVisit(fetchedAt)).toBe(false);
    }
    // The oldest is forgotten, so it counts as new (and pushes out the next oldest); the 49 after that are still known.
    expect(refetchedOnVisit(oldest)).toBe(false);
    expect(refetchedOnVisit(later[0])).toBe(false);
    expect(refetchedOnVisit(later[2])).toBe(true);
  });

  it("without a stamp the page counts as new", () => {
    firstPageServer();
    expect(refetchedOnVisit(undefined)).toBe(false);
    expect(refetchedOnVisit(undefined)).toBe(false);
  });
});
