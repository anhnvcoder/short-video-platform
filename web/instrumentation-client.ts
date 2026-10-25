import { handleClientError } from "@/features/monitoring/reporter";

// Runs in the browser before the app hydrates: errors nothing caught are reported, and a chunk that failed to load
// reloads the page once.

window.addEventListener("error", (event) => {
  // No error object: a cross-origin script's "Script error.", which says nothing.
  if (event.error !== null && event.error !== undefined) {
    handleClientError(event.error);
  }
});

window.addEventListener("unhandledrejection", (event) => {
  handleClientError(event.reason);
});
