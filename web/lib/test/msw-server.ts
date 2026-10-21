import { setupServer } from "msw/node";

// One request interceptor for the whole unit run (started in vitest.setup.ts); a test adds its handlers with
// `server.use(...)`, and they are reset after each test.
export const server = setupServer();
