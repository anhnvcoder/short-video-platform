// Counts real playback of one view of a video and reports the view once it reaches the threshold
// (docs/adr/0016-web-client.md, section 8): the gap in currentTime between two `timeupdate` events counts only while
// the video plays, the page is visible and no seek is running, and only when the gap is small. A seek, a loop back to
// the start or a long stall in between moves currentTime by more than a normal gap (browsers fire `timeupdate` every
// 15–250 ms), so it adds nothing.

export const viewThresholdSeconds = 2;
// Largest gap between two timeupdate events that still counts as playback.
const maxGapSeconds = 1;

export interface PlaybackSample {
  currentTime: number;
  playing: boolean;
  seeking: boolean;
  hidden: boolean;
}

export class ViewCounter {
  private watched = 0;
  private last: number | null = null;
  private reported = false;

  constructor(
    private readonly onView: () => void,
    private readonly thresholdSeconds = viewThresholdSeconds,
  ) {}

  // One `timeupdate`.
  sample({ currentTime, playing, seeking, hidden }: PlaybackSample): void {
    if (this.reported) {
      return;
    }
    if (!playing || seeking || hidden) {
      // The next sample starts a new gap: time spent paused, hidden or seeking never counts.
      this.last = null;
      return;
    }
    const previous = this.last;
    this.last = currentTime;
    if (previous === null) {
      return;
    }
    const gap = currentTime - previous;
    if (gap > 0 && gap <= maxGapSeconds) {
      this.watched += gap;
    }
    if (this.watched >= this.thresholdSeconds) {
      this.reported = true;
      this.onView();
    }
  }

  // A seek started or ended, or playback paused: the gap across it is not playback.
  interrupt(): void {
    this.last = null;
  }
}
