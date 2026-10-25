import { useRef, useState } from "react";
import { setFollowing, type FeedKind } from "./api";

export interface Follows {
  isFollowing(authorId: string): boolean;
  isPending(authorId: string): boolean;
  toggle(authorId: string): void;
}

// Follow state of the authors on this page. The gateway does not say whether
// the caller follows an author, so the following feed starts with every author followed and the explore feed with
// none; a tap changes the state once the server has confirmed it, for every video of that author on the page.
export function useFollows(kind: FeedKind, onError: (error: unknown, wanted: boolean) => void): Follows {
  const [follows, setFollows] = useState<Record<string, boolean>>({});
  const [pending, setPending] = useState<Record<string, boolean>>({});
  // Guards against a second tap before the first one's state has rendered.
  const inFlight = useRef(new Set<string>());

  const isFollowing = (authorId: string) => follows[authorId] ?? kind === "following";

  async function toggle(authorId: string) {
    if (inFlight.current.has(authorId)) {
      return;
    }
    inFlight.current.add(authorId);
    const wanted = !isFollowing(authorId);
    setPending((current) => ({ ...current, [authorId]: true }));
    try {
      await setFollowing(authorId, wanted);
      setFollows((current) => ({ ...current, [authorId]: wanted }));
    } catch (error) {
      onError(error, wanted);
    } finally {
      inFlight.current.delete(authorId);
      setPending((current) => ({ ...current, [authorId]: false }));
    }
  }

  return {
    isFollowing,
    isPending: (authorId) => pending[authorId] ?? false,
    toggle: (authorId) => void toggle(authorId),
  };
}
