import { unstable_isUnrecognizedActionError } from "next/navigation";

// A page of one build talking to a server of another (a canary, a tab opened before a release) gets two errors Next
// does not recover from by itself: a chunk only the
// other build has (404), and a Server Action id the other build does not know (409, UnrecognizedActionError). Loading
// the page again fetches the current build's HTML and chunks; the action had not run, so sending it again is safe.

// Turbopack's runtime raises this for a JS or CSS chunk it could not load, a dynamic import() included.
function isChunkLoadError(error: unknown): boolean {
  return error instanceof Error && error.name === "ChunkLoadError" && error.message.startsWith("Failed to load chunk");
}

// Next's own check, behind a check of the name: an ordinary error never reaches next/navigation's helper (which a
// test of an unrelated component may have mocked away).
function isUnrecognizedActionError(error: unknown): boolean {
  return (
    error instanceof Error && error.name === "UnrecognizedActionError" && unstable_isUnrecognizedActionError(error)
  );
}

// Reloads the page and returns true for such an error, once per build: the key names the build, so a reload that
// lands on the other build may reload once more, and an asset that is really gone ends at the caller's error path
// instead of a loop. Returns false for any other error, or when this build has reloaded already.
export function reloadOnceOnSkew(error: unknown): boolean {
  if (!isChunkLoadError(error) && !isUnrecognizedActionError(error)) {
    return false;
  }
  // Next sets the id from next.config's deploymentId; without one every build is "dev".
  const key = `svp:skew-reload:${process.env.NEXT_DEPLOYMENT_ID || "dev"}`;
  try {
    if (sessionStorage.getItem(key) !== null) {
      return false;
    }
    sessionStorage.setItem(key, "1");
  } catch {
    // No sessionStorage (blocked, full): nothing would stop a loop, so no reload.
    return false;
  }
  location.reload();
  return true;
}
