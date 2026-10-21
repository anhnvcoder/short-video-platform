import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Tests live next to the code they test; e2e/ (Playwright) is not part of the unit run.
const sources = "{app,components,features,i18n,lib,server}";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": fileURLToPath(new URL(".", import.meta.url)) },
  },
  test: {
    setupFiles: ["./vitest.setup.ts"],
    projects: [
      {
        extends: true,
        test: {
          name: "node",
          environment: "node",
          include: [`${sources}/**/*.test.ts`],
        },
        resolve: {
          // Server modules start with `import "server-only"`, which throws outside the react-server condition of a
          // Next build. Code run here is server code by definition, so the marker resolves to its empty variant; the
          // jsdom project keeps the throwing one, so a component that imports a server module still fails there.
          alias: { "server-only": fileURLToPath(new URL("./node_modules/server-only/empty.js", import.meta.url)) },
        },
      },
      {
        extends: true,
        test: {
          name: "jsdom",
          environment: "jsdom",
          include: [`${sources}/**/*.test.tsx`],
        },
      },
    ],
  },
});
