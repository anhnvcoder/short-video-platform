import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { seedEnv } from "./seed";

// Once per run, before any browser starts: e2e/seed.sh resets the register rate limit (LOCAL LAB ONLY) and makes sure
// explore holds the videos the tests need. Its answer reaches the tests through the environment, which Playwright
// passes on to its workers.
export default function globalSetup() {
  const dir = mkdtempSync(join(tmpdir(), "svp-e2e-"));
  try {
    const out = join(dir, "seed.json");
    execFileSync("bash", [join(import.meta.dirname, "seed.sh"), out], { stdio: ["ignore", "inherit", "inherit"] });
    process.env[seedEnv] = readFileSync(out, "utf8");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
