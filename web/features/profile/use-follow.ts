import { useRef, useState } from "react";
import { setFollowing } from "@/features/feed/api";

export interface Follow {
  following: boolean;
  pending: boolean;
  toggle(): void;
}

// Follow state of the profile shown, starting from the gateway's `followed_by_me`. A tap changes it once the server has
// confirmed it (PUT or DELETE /api/me/following/<id>); a failure keeps the state and goes to `onError`.
export function useFollow(
  userId: string,
  followedByMe: boolean,
  onError: (error: unknown, wanted: boolean) => void,
): Follow {
  const [following, setFollowingState] = useState(followedByMe);
  const [pending, setPending] = useState(false);
  // Guards against a second tap before the first one's state has rendered.
  const inFlight = useRef(false);

  async function toggle() {
    if (inFlight.current) {
      return;
    }
    inFlight.current = true;
    const wanted = !following;
    setPending(true);
    try {
      await setFollowing(userId, wanted);
      setFollowingState(wanted);
    } catch (error) {
      onError(error, wanted);
    } finally {
      inFlight.current = false;
      setPending(false);
    }
  }

  return { following, pending, toggle: () => void toggle() };
}
