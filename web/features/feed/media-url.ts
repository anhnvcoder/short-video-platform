// Playlist and thumbnail URLs come from the API. They are used only when they point at the media origin the server
// configured (MEDIA_ORIGIN, also the only media origin the CSP allows); anything else counts as a playback error and
// gets no poster.
export function isMediaUrl(value: string, mediaOrigin: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return (url.protocol === "http:" || url.protocol === "https:") && url.origin === mediaOrigin;
}
