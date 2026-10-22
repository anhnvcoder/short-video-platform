// Numbers of the upload screens, as the design writes them: "19,2 MB", "2,1 MB/s", "0:42".

// MB of the screens is 2^20 bytes, so the limit of 524 288 000 bytes reads "500 MB".
const bytesPerMegabyte = 1024 * 1024;

export function formatMegabytes(bytes: number, locale: string): string {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(bytes / bytesPerMegabyte);
}

// m:ss, or h:mm:ss from an hour on.
export function formatDuration(seconds: number): string {
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}

// Seconds left at the current speed, rounded up; null while the speed is unknown.
export function secondsLeft(sizeBytes: number, progress: number, bytesPerSecond: number | null): number | null {
  if (bytesPerSecond === null || bytesPerSecond <= 0) {
    return null;
  }
  return Math.max(1, Math.ceil((sizeBytes * (1 - progress)) / bytesPerSecond));
}
