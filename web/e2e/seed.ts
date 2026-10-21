// The seed of e2e/seed.sh, handed from e2e/global-setup.ts to the tests.

// The environment variable e2e/global-setup.ts puts the seed into.
export const seedEnv = "SVP_E2E_SEED";

export type Seed = {
  // The newest READY video, first in explore, with an HTML title (WEB-1); its author has no other video.
  xss: { video_id: string; author_id: string; title: string };
  explore_ready: number;
};

export function seed(): Seed {
  const raw = process.env[seedEnv];
  if (!raw) {
    throw new Error(`${seedEnv} is not set: e2e/global-setup.ts did not run`);
  }
  return JSON.parse(raw) as Seed;
}
