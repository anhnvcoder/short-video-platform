import { useQuery, type Query } from "@tanstack/react-query";
import { fetchVideo, UploadApiError, type Video } from "./api";

// Waiting for the worker after the upload: GET /videos/{id} every 2 s at first, then 1.5 times longer each time up to
// 10 s, until the video is READY or FAILED. A clip takes from seconds to minutes, so the first answers come quickly and
// a long transcode costs few requests.
const firstPollMs = 2000;
const pollGrowth = 1.5;
const maxPollMs = 10_000;

export function pollDelayMs(polls: number): number {
  return Math.min(firstPollMs * pollGrowth ** polls, maxPollMs);
}

function settled(video: Video | undefined): boolean {
  return video?.status === "READY" || video?.status === "FAILED";
}

function nextPoll(query: Query<Video, Error, Video, readonly unknown[]>): number | false {
  const { data, error, dataUpdateCount, errorUpdateCount } = query.state;
  if (settled(data)) {
    return false;
  }
  if (error instanceof UploadApiError) {
    if (error.status === 401) {
      // The page sends the user to log in.
      return false;
    }
    if (error.retryAfterSeconds !== undefined) {
      return error.retryAfterSeconds * 1000;
    }
  }
  return pollDelayMs(dataUpdateCount + errorUpdateCount);
}

// `video` is the answer of completing it. Polling stops when the component unmounts (the request in flight is
// aborted) and pauses while the tab is hidden; coming back to the tab polls at once.
export function useVideoStatus(video: Video) {
  return useQuery({
    queryKey: ["upload", "video", video.video_id] as const,
    queryFn: ({ signal }) => fetchVideo(video.video_id, signal),
    initialData: video,
    // The answer of completing is fresh: the first poll waits for its interval.
    refetchOnMount: false,
    refetchOnWindowFocus: (query) => !settled(query.state.data),
    refetchInterval: nextPoll,
    // A failed poll is followed by the next one at the interval.
    retry: false,
  });
}
