"use client";

import { useEffect, useState } from "react";

// Whole seconds left of a wait that starts at `seconds` (null: no wait) and runs down to 0. A new `key` (the form state
// of a new answer, the error of a new failure) starts the wait again, even with the same number of seconds.
//
// The count is read from a deadline, not from the number of timer callbacks: a phone pauses the timers of a page in the
// background and a sleeping laptop fires them late, so counting callbacks would keep the button locked past the
// server's Retry-After. Coming back to the tab reads the clock again at once.
export function useCountdown(seconds: number | null, key: unknown): number {
  const [current, setCurrent] = useState({ key, left: seconds ?? 0 });
  let left = current.left;
  if (current.key !== key) {
    // Reset while rendering rather than in an effect, so the old count never shows for one frame.
    left = seconds ?? 0;
    setCurrent({ key, left });
  }
  useEffect(() => {
    if (seconds === null || seconds <= 0) {
      return;
    }
    // Read the clock here, not while rendering: the server render and hydration must show the same full count.
    const deadline = Date.now() + seconds * 1000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    function update() {
      clearTimeout(timer);
      const remaining = deadline - Date.now();
      const next = Math.max(0, Math.ceil(remaining / 1000));
      setCurrent({ key, left: next });
      if (next > 0) {
        // Wake up when the shown number changes, not a fixed second later.
        timer = setTimeout(update, remaining - (next - 1) * 1000);
      }
    }
    timer = setTimeout(update, 1000);
    document.addEventListener("visibilitychange", update);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", update);
    };
  }, [seconds, key]);
  return left;
}
