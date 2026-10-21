import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

// eslint-config-next registers jsx-a11y but turns on only a handful of its rules; take the plugin from there (pnpm does
// not hoist it for this file to import) and turn on its whole recommended set.
const jsxA11y = nextVitals.find((config) => config.plugins?.["jsx-a11y"])?.plugins["jsx-a11y"];
if (!jsxA11y) {
  throw new Error("eslint-config-next no longer registers eslint-plugin-jsx-a11y");
}

export default defineConfig([
  ...nextVitals,
  ...nextTs,
  {
    rules: {
      ...jsxA11y.flatConfigs.recommended.rules,
      // Text from users (titles, names) is rendered as React text only: raw HTML would be a stored XSS (WEB-1).
      "react/no-danger": "error",
      "@typescript-eslint/no-unused-vars": "error",
    },
  },
  globalIgnores([
    ".next/**",
    "gen/**",
    "design/**",
    "coverage/**",
    "test-results/**",
    "playwright-report/**",
    "next-env.d.ts",
  ]),
]);
