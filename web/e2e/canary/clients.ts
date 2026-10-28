import { randomBytes } from "node:crypto";
import { appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { chromium, type BrowserContext, type Page, type Response } from "@playwright/test";

// Browser clients of `make drill-k8s-web-canary` (deploy/k8s/drills/web-canary.sh), one run per canary: started on the
// stable build before the canary, stopped (SIGTERM) once it is over. Each client is a Chromium context of its own (its
// own cookie and sessionStorage, so the reload-once key of features/monitoring/skew-reload.ts starts empty every run),
// logged in through the login page as a fresh user registered at the gateway, and then:
// - every second GET /api/feed/explore with its session cookie (the BFF calls the gateway: the route a canary whose
//   GATEWAY_URL is broken answers 502 on);
// - a normal client goes round Following, Profile (/me), where it changes its display name through the form's Server
//   Action, and Home, a step every 4 s, by its links and tabs (client-side navigations, RSC requests);
// - the old tab (OLD_TAB=1, client c0) opens /me before the canary and sends the display name form every 3 s without
//   navigating itself: the page of the stable build whose Server Action reaches a canary pod of another build.
// The media origin and the error tunnel /monitoring are blocked: no video is decoded on the runner, and the errors of
// players without media are not sent to GlitchTip.
//
// Per client it counts the signals of a page of one build served by another: a Server Action answered 409 with
// x-nextjs-action-not-found, a /_next/static file answered 404, an RSC or action response whose x-nextjs-deployment-id
// is not the x-deployment-id the page sent. And every document load it did not ask for itself, by the type the new
// document's Navigation Timing gives: "reload" is location.reload() of reloadOnceOnSkew (cause: the signal seen just
// before, action or chunk), "navigate" is Next's own full-page navigation (cause: a deployment id mismatch just before,
// or other). The builds come from ?dpl=<build> of the documents' scripts and from x-nextjs-deployment-id.
//
// Writes only numbers, times and route names: OUT_DIR/clients.log, one line per same-origin response or document
// load in the format of the drill traffic's log (<start ms> <client> <route> <status, 000 when none> <ms>), and once
// stopped OUT_DIR/clients.json, the counters of every client. OUT_DIR/ready appears once every client is set up. No
// trace, video, screenshot, HAR, cookie or password goes to any file; the passwords stay in this process.
//
// Usage (from web/, NODE_EXTRA_CA_CERTS set to the cluster's CA):
//   node e2e/canary/clients.ts WEB_ORIGIN GATEWAY_URL MEDIA_ORIGIN OUT_DIR CLIENTS OLD_TAB
const usage = "usage: node e2e/canary/clients.ts WEB_ORIGIN GATEWAY_URL MEDIA_ORIGIN OUT_DIR CLIENTS OLD_TAB(0|1)";
const [webOrigin, gatewayURL, mediaOrigin, outDir, clientsArg, oldTabArg] = process.argv.slice(2);
if (
  !webOrigin ||
  !gatewayURL ||
  !mediaOrigin ||
  !outDir ||
  !/^[1-9]$/.test(clientsArg ?? "") ||
  !/^[01]$/.test(oldTabArg ?? "")
) {
  throw new Error(usage);
}
const clientCount = Number(clientsArg);
const oldTab = oldTabArg === "1";
const logFile = join(outDir, "clients.log");

// The key prefix of reloadOnceOnSkew: one key per build whose page reloaded.
const skewKeyPrefix = "svp:skew-reload:";
// A signal explains a document load that follows it within this time.
const signalWindowMs = 15_000;

type SignalKind = "action" | "chunk" | "deployment";

type Client = {
  name: string;
  role: "old-tab" | "client";
  context: BrowserContext;
  page: Page;
  // The build of the page when the run started counting, and of the latest document.
  startBuild: string | null;
  build: string | null;
  builds: Record<string, number>;
  signals: Record<SignalKind, number>;
  lastSignal: { kind: SignalKind; at: number } | null;
  firstSignalAt: number | null;
  reloads: { action: number; chunk: number; other: number };
  // The builds whose page reloaded, from the reload-once keys each reload added, in order.
  reloadBuilds: string[];
  mpa: { deployment: number; other: number };
  ownLoads: number;
  // Set while the client itself loads a document (page.goto), so that load is not counted as a reload.
  ownLoad: boolean;
  documents: number;
  recoveries: number;
  knownKeys: Set<string>;
  actions: { sent: number; status409: number; byStatus: Record<string, number> };
  api: { requests: number; byStatus: Record<string, number> };
};

type DocumentInfo = { type: string; keys: string[]; build: string | null };

let counting = false;
let stopping = false;

function bump(counts: Record<string, number>, key: string): void {
  counts[key] = (counts[key] ?? 0) + 1;
}

function log(start: number, client: string, route: string, status: number, ms: number): void {
  const code = status > 0 ? String(status) : "000";
  appendFileSync(logFile, `${Math.round(start)} ${client} ${route} ${code} ${Math.max(0, Math.round(ms))}\n`);
}

function signal(client: Client, kind: SignalKind): void {
  const at = Date.now();
  client.lastSignal = { kind, at };
  if (counting) {
    client.signals[kind] += 1;
    client.firstSignalAt ??= at;
  }
}

function recentSignal(client: Client): SignalKind | null {
  const last = client.lastSignal;
  return last && Date.now() - last.at <= signalWindowMs ? last.kind : null;
}

function onResponse(client: Client, response: Response): void {
  const request = response.request();
  const url = new URL(response.url());
  if (url.origin !== webOrigin) {
    return;
  }
  const headers = request.headers();
  const status = response.status();
  const timing = request.timing();
  let route: string;
  if (request.isNavigationRequest() && request.frame() === client.page.mainFrame()) {
    route = "document";
  } else if (headers["next-action"] !== undefined) {
    route = "action";
  } else if (headers["rsc"] === "1") {
    route = "rsc";
  } else if (url.pathname.startsWith("/_next/static/")) {
    route = "static";
  } else {
    route = "other";
  }
  const served = response.headers()["x-nextjs-deployment-id"];
  if (served && counting) {
    bump(client.builds, served);
  }
  if (route === "action") {
    if (counting) {
      client.actions.sent += 1;
      bump(client.actions.byStatus, String(status));
    }
    if (status === 409 && response.headers()["x-nextjs-action-not-found"] === "1") {
      if (counting) {
        client.actions.status409 += 1;
      }
      signal(client, "action");
    }
  }
  if (route === "static" && status === 404) {
    signal(client, "chunk");
  }
  const sent = headers["x-deployment-id"];
  if ((route === "rsc" || route === "action") && served && sent && served !== sent) {
    signal(client, "deployment");
  }
  if (counting) {
    log(timing.startTime, client.name, route, status, timing.responseStart);
  }
}

// Called by the init script of every document once it is parsed.
function onDocument(client: Client, info: DocumentInfo): void {
  const added = info.keys.filter((key) => !client.knownKeys.has(key));
  for (const key of info.keys) {
    client.knownKeys.add(key);
  }
  client.build = info.build;
  if (!counting) {
    client.ownLoad = false;
    return;
  }
  client.documents += 1;
  if (info.build) {
    bump(client.builds, info.build);
  }
  const cause = recentSignal(client);
  let kind: string;
  if (client.ownLoad) {
    client.ownLoad = false;
    client.ownLoads += 1;
    kind = "own";
  } else if (info.type === "reload") {
    const reason = cause === "action" || cause === "chunk" ? cause : "other";
    client.reloads[reason] += 1;
    client.reloadBuilds.push(...added.map((key) => key.slice(skewKeyPrefix.length)));
    kind = `reload-${reason}`;
  } else {
    const reason = cause === "deployment" ? "deployment" : "other";
    client.mpa[reason] += 1;
    kind = `mpa-${reason}`;
  }
  client.lastSignal = null;
  log(Date.now(), client.name, kind, 200, 0);
}

// Reports each document's navigation type, its reload-once keys and its build to onDocument.
function documentProbe(): void {
  addEventListener("DOMContentLoaded", () => {
    const navigation = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming | undefined;
    let keys: string[] = [];
    try {
      keys = Object.keys(sessionStorage).filter((key) => key.startsWith("svp:skew-reload:"));
    } catch {
      // No sessionStorage: reloadOnceOnSkew does not reload either.
    }
    const script = Array.from(document.scripts).find((element) => element.src.includes("dpl="));
    const build = script ? new URL(script.src).searchParams.get("dpl") : null;
    const report = (window as unknown as { __svpCanaryDocument: (info: unknown) => void }).__svpCanaryDocument;
    report({ type: navigation?.type ?? "unknown", keys, build });
  });
}

async function register(): Promise<{ email: string; password: string }> {
  const account = {
    email: `canary-${Date.now()}-${randomBytes(4).toString("hex")}@example.test`,
    password: randomBytes(16).toString("hex"),
    handle: `canary_${randomBytes(6).toString("hex")}`,
  };
  const response = await fetch(`${gatewayURL}/auth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(account),
    signal: AbortSignal.timeout(10_000),
  });
  if (response.status !== 201) {
    throw new Error(`register at the gateway answered ${response.status}`);
  }
  return { email: account.email, password: account.password };
}

// A document load the client asks for itself: not a reload or navigation of the app.
async function ownGoto(client: Client, path: string): Promise<void> {
  client.ownLoad = true;
  try {
    await client.page.goto(path, { timeout: 15_000 });
  } finally {
    // The probe's report of that document arrives before `load`; one that never came leaves nothing pending.
    client.ownLoad = false;
  }
}

async function setUp(index: number, browser: Awaited<ReturnType<typeof chromium.launch>>): Promise<Client> {
  const credentials = await register();
  // Small screen: the bottom navigation (Home, Upload, Profile) shows. English copy, so the controls have the names
  // of messages/en. The cluster's certificate comes from its own CA, which the browser does not know.
  const context = await browser.newContext({
    baseURL: webOrigin,
    locale: "en-US",
    viewport: { width: 390, height: 844 },
    ignoreHTTPSErrors: true,
  });
  await context.route(`${mediaOrigin}/**`, (route) => route.abort());
  await context.route(`${webOrigin}/monitoring**`, (route) => route.abort());
  const page = await context.newPage();
  const client: Client = {
    name: `c${index}`,
    role: oldTab && index === 0 ? "old-tab" : "client",
    context,
    page,
    startBuild: null,
    build: null,
    builds: {},
    signals: { action: 0, chunk: 0, deployment: 0 },
    lastSignal: null,
    firstSignalAt: null,
    reloads: { action: 0, chunk: 0, other: 0 },
    reloadBuilds: [],
    mpa: { deployment: 0, other: 0 },
    ownLoads: 0,
    ownLoad: false,
    documents: 0,
    recoveries: 0,
    knownKeys: new Set(),
    actions: { sent: 0, status409: 0, byStatus: {} },
    api: { requests: 0, byStatus: {} },
  };
  await context.exposeBinding("__svpCanaryDocument", (_source, info: DocumentInfo) => onDocument(client, info));
  await context.addInitScript(documentProbe);
  page.on("response", (response) => onResponse(client, response));

  await ownGoto(client, "/login");
  await page.getByLabel("Email").fill(credentials.email);
  // Exact: the eye button next to the field is labelled "Show password".
  await page.getByLabel("Password", { exact: true }).fill(credentials.password);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await page.waitForURL("/", { timeout: 15_000 });
  if (client.role === "old-tab") {
    await ownGoto(client, "/me");
    await page.getByText("Change display name").waitFor({ timeout: 15_000 });
  }
  return client;
}

async function pause(ms: number): Promise<void> {
  const end = Date.now() + ms;
  while (!stopping && Date.now() < end) {
    await new Promise((resolve) => setTimeout(resolve, Math.min(250, end - Date.now())));
  }
}

async function apiLoop(client: Client): Promise<void> {
  while (!stopping) {
    const start = Date.now();
    let status = 0;
    try {
      const response = await client.context.request.get("/api/feed/explore", {
        timeout: 10_000,
        failOnStatusCode: false,
      });
      status = response.status();
      await response.dispose();
    } catch {
      // No answer: logged as 000.
    }
    if (counting) {
      client.api.requests += 1;
      bump(client.api.byStatus, status > 0 ? String(status) : "000");
      log(start, client.name, "api", status, Date.now() - start);
    }
    await pause(1000 - (Date.now() - start));
  }
}

let nameCount = 0;

// Sends the display name form of /me: its Server Action changes the user's own display name.
async function sendName(client: Client): Promise<void> {
  const { page } = client;
  const field = page.getByLabel("Display name");
  if (!(await field.isVisible())) {
    await page.getByText("Change display name").click({ timeout: 5000 });
  }
  nameCount += 1;
  await field.fill(`canary ${client.name} ${nameCount}`, { timeout: 5000 });
  await page.getByRole("button", { name: "Save name" }).click({ timeout: 5000 });
}

function navLink(page: Page, name: string) {
  return page.getByRole("link", { name, exact: true }).filter({ visible: true }).first();
}

async function browseLoop(client: Client): Promise<void> {
  const { page } = client;
  const steps: Array<() => Promise<void>> =
    client.role === "old-tab"
      ? [() => sendName(client)]
      : [
          () => page.getByRole("tab", { name: "Following" }).click({ timeout: 5000 }),
          () => navLink(page, "Profile").click({ timeout: 5000 }),
          () => sendName(client),
          () => navLink(page, "Home").click({ timeout: 5000 }),
        ];
  const home = client.role === "old-tab" ? "/me" : "/";
  for (let i = 0; !stopping; i += 1) {
    try {
      await steps[i % steps.length]!();
    } catch {
      // Not the screen the step expects (an error screen, a page still loading): back to the client's page.
      if (stopping) {
        break;
      }
      client.recoveries += 1;
      await ownGoto(client, home).catch(() => {});
    }
    await pause(client.role === "old-tab" ? 3000 : 4000);
  }
}

function summary(client: Client) {
  return {
    client: client.name,
    role: client.role,
    start_build: client.startBuild,
    builds_seen: client.builds,
    signals: {
      action_409: client.signals.action,
      chunk_404: client.signals.chunk,
      deployment_mismatch: client.signals.deployment,
      total: client.signals.action + client.signals.chunk + client.signals.deployment,
    },
    first_signal_at_ms: client.firstSignalAt,
    reloads: { ...client.reloads, total: client.reloads.action + client.reloads.chunk + client.reloads.other },
    reload_builds: client.reloadBuilds,
    mpa_navigations: { ...client.mpa, total: client.mpa.deployment + client.mpa.other },
    own_loads: client.ownLoads,
    documents: client.documents,
    recoveries: client.recoveries,
    actions: { sent: client.actions.sent, status_409: client.actions.status409, by_status: client.actions.byStatus },
    api: { requests: client.api.requests, by_status: client.api.byStatus },
  };
}

writeFileSync(logFile, "", { mode: 0o600 });
const browser = await chromium.launch();
const clients: Client[] = [];
for (let i = 0; i < clientCount; i += 1) {
  clients.push(await setUp(i, browser));
}
for (const client of clients) {
  client.startBuild = client.build;
}
counting = true;
writeFileSync(join(outDir, "ready"), "", { mode: 0o600 });
console.log(`ok    ${clientCount} browser clients ready${oldTab ? " (c0 the old tab on /me)" : ""}`);

const done = new Promise<void>((resolve) => {
  const stop = () => {
    stopping = true;
    resolve();
  };
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
});
const loops = clients.flatMap((client) => [apiLoop(client), browseLoop(client)]);
await done;
await Promise.allSettled(loops);
counting = false;
writeFileSync(join(outDir, "clients.json"), JSON.stringify(clients.map(summary)), { mode: 0o600 });
await browser.close();
