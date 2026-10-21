import { useRef, useState } from "react";
import { setLiked, type VideoStats } from "./api";

export interface LikeToggle {
  liked: boolean;
  // Null when the feed came without stats: the count is hidden, never shown as 0.
  count: number | null;
  toggle(): void;
}

// Optimistic like of one video. The button changes at once; the server is brought to the state of the last tap by one
// request at a time, so taps in quick succession never race each other and the end state is always the last tap's.
// A failed request puts the button back to what the server last confirmed and calls `onError` with the state of the
// last tap and a function that asks for that state again.
//
// Until the first tap the button shows `stats` as they come, so a page the feed fetched again brings the server's newer
// answer; from the first tap on, the taps decide.
export function useLike(
  videoId: string,
  stats: VideoStats | undefined,
  onError: (error: unknown, wanted: boolean, retry: () => void) => void,
): LikeToggle {
  const fromServer = stats?.liked_by_me ?? false;
  // Null until the first tap.
  const [tapped, setTapped] = useState<boolean | null>(null);
  const liked = tapped ?? fromServer;
  const touched = useRef(false);
  const confirmed = useRef(false);
  const wanted = useRef(false);
  const running = useRef(false);

  // `force` sends the wanted state even when it matches the confirmed one: after a failure the server's state is not
  // known (the request may have been applied before the answer was lost), and PUT and DELETE are safe to repeat.
  async function sync(force: boolean) {
    running.current = true;
    try {
      while (force || wanted.current !== confirmed.current) {
        force = false;
        const target = wanted.current;
        await setLiked(videoId, target);
        confirmed.current = target;
      }
    } catch (error) {
      const target = wanted.current;
      wanted.current = confirmed.current;
      setTapped(confirmed.current);
      onError(error, target, () => want(target, true));
    } finally {
      running.current = false;
    }
  }

  function want(state: boolean, force: boolean) {
    wanted.current = state;
    setTapped(state);
    if (!running.current) {
      void sync(force);
    }
  }

  function toggle() {
    if (!touched.current) {
      // The taps start from the server's latest answer.
      touched.current = true;
      confirmed.current = fromServer;
      wanted.current = fromServer;
    }
    want(!wanted.current, false);
  }

  // The count without the caller's own like, plus the like the button shows. Counts lag, so never below zero.
  const count = stats ? Math.max(0, stats.like_count - (stats.liked_by_me ? 1 : 0) + (liked ? 1 : 0)) : null;
  return { liked, count, toggle };
}
