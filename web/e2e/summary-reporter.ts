import type { Reporter, Suite } from "@playwright/test/reporter";

// One line per browser at the end of a run: how many tests passed, failed, were skipped, or never ran (the run
// stopped first). The list reporter prints only the totals of all projects together.
export default class SummaryReporter implements Reporter {
  private root: Suite | undefined;

  onBegin(_config: unknown, suite: Suite): void {
    this.root = suite;
  }

  onEnd(): void {
    for (const project of this.root?.suites ?? []) {
      const counts = { passed: 0, failed: 0, flaky: 0, skipped: 0, "did not run": 0 };
      for (const test of project.allTests()) {
        if (test.results.length === 0) {
          counts["did not run"] += 1;
          continue;
        }
        const outcome = test.outcome();
        counts[outcome === "expected" ? "passed" : outcome === "unexpected" ? "failed" : outcome] += 1;
      }
      const parts = Object.entries(counts)
        .filter(([name, n]) => n > 0 || name === "passed" || name === "failed")
        .map(([name, n]) => `${n} ${name}`);
      console.log(`e2e ${project.title}: ${parts.join(", ")}`);
    }
  }
}
