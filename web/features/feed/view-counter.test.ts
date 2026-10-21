import { describe, expect, it, vi } from "vitest";
import { ViewCounter, type PlaybackSample } from "./view-counter";

const playing = { playing: true, seeking: false, hidden: false };

// timeupdate events every 250 ms of playback from `from` to `to` seconds.
function play(counter: ViewCounter, from: number, to: number, state: Partial<PlaybackSample> = {}) {
  for (let time = from; time <= to + 1e-9; time += 0.25) {
    counter.sample({ ...playing, ...state, currentTime: time });
  }
}

describe("ViewCounter", () => {
  it("reports one view after 2 s of playback, and never again", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 0, 1.75);
    expect(onView).not.toHaveBeenCalled();
    play(counter, 2, 2);
    expect(onView).toHaveBeenCalledTimes(1);
    play(counter, 2.25, 30);
    expect(onView).toHaveBeenCalledTimes(1);
  });

  it("does not count a seek forward", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 0, 1);
    // The user drags to 20 s: one jump of 19 s between two timeupdates.
    counter.sample({ ...playing, currentTime: 20 });
    expect(onView).not.toHaveBeenCalled();
    play(counter, 20.25, 20.75);
    expect(onView).not.toHaveBeenCalled();
    play(counter, 21, 21);
    expect(onView).toHaveBeenCalledTimes(1);
  });

  it("does not count time while seeking, nor a small step across a seek", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 0, 1.5);
    counter.interrupt();
    counter.sample({ ...playing, seeking: true, currentTime: 1.75 });
    // After the seek ends, 0.5 s later in the video: the first sample only starts a new gap.
    counter.sample({ ...playing, currentTime: 2.25 });
    expect(onView).not.toHaveBeenCalled();
    play(counter, 2.5, 2.75);
    expect(onView).toHaveBeenCalledTimes(1);
  });

  it("does not count a seek back or a loop to the start", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 5, 6.5);
    counter.sample({ ...playing, currentTime: 0 });
    expect(onView).not.toHaveBeenCalled();
    play(counter, 0.25, 0.5);
    expect(onView).toHaveBeenCalledTimes(1);
  });

  it("does not count while the page is hidden", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 0, 1.5);
    // Some browsers keep firing timeupdate for a hidden tab.
    play(counter, 1.75, 10, { hidden: true });
    expect(onView).not.toHaveBeenCalled();
    // Visible again: the first sample starts a new gap, and 0.5 s more reaches 2 s.
    play(counter, 10.25, 10.75);
    expect(onView).toHaveBeenCalledTimes(1);
  });

  it("does not count while paused", () => {
    const onView = vi.fn();
    const counter = new ViewCounter(onView);
    play(counter, 0, 1);
    play(counter, 1, 5, { playing: false });
    play(counter, 1.25, 1.75);
    expect(onView).not.toHaveBeenCalled();
    play(counter, 2, 2.5);
    expect(onView).toHaveBeenCalledTimes(1);
  });
});
