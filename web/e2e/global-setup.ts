import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { seedEnv } from "./seed";
import { stack } from "./stack";

// Once per run, before any browser starts: e2e/seed.sh resets the register rate limit (LOCAL LAB ONLY) and makes sure
// explore holds the videos the tests need. Its answer reaches the tests through the environment, which Playwright
// passes on to its workers.
export default function globalSetup() {
  // On k3d, curl (the seed) and Node (the specs' fetch) must trust the cluster's CA, and Node reads its variable only
  // as it starts: the run goes through e2e/k3d-e2e.sh, which sets both.
  if (stack.name === "k3d" && !(process.env.CURL_CA_BUNDLE && process.env.NODE_EXTRA_CA_CERTS)) {
    throw new Error("SVP_STACK=k3d needs CURL_CA_BUNDLE and NODE_EXTRA_CA_CERTS (.k8s/ca.crt): run make k8s-web-e2e");
  }
  const dir = mkdtempSync(join(tmpdir(), "svp-e2e-"));
  try {
    const out = join(dir, "seed.json");
    execFileSync("bash", [join(import.meta.dirname, "seed.sh"), out], {
      stdio: ["ignore", "inherit", "inherit"],
      env: { ...process.env, SVP_E2E_GATEWAY_URL: stack.gatewayURL },
    });
    process.env[seedEnv] = readFileSync(out, "utf8");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
