// The stack an end-to-end run talks to, from SVP_STACK: `compose` (default, `make web-e2e`) or `k3d` (`make
// k8s-web-e2e`). Every origin, and the session cookie's form, comes from here, so no spec names one stack's address.
//
// compose: the `web` container at http://localhost:3001, the gateway and the object store (service s3) on their
// loopback ports. Plain http, so the session cookie has no prefix and no Secure.
// k3d: cluster svp behind Envoy on 127.0.0.1:8443, one name per route:
// the web at https://svp.localhost:8443, the gateway at
// api.svp.localhost, the storage (uploads and media) at s3.svp.localhost; every *.localhost name resolves to loopback
// in Chromium and WebKit alike. https, so the cookie is __Host-Http-svp_sid with Secure. The cluster's certificates
// come from its own CA (.k8s/ca.crt).

const name = process.env.SVP_STACK || "compose";
if (name !== "compose" && name !== "k3d") {
  throw new Error(`SVP_STACK must be compose or k3d (got ${name})`);
}
const k3d = name === "k3d";

export const stack = {
  name,
  appOrigin: k3d ? "https://svp.localhost:8443" : "http://localhost:3001",
  gatewayURL: k3d ? "https://api.svp.localhost:8443" : "http://127.0.0.1:8080",
  // UPLOAD_ORIGIN of the web; MEDIA_ORIGIN is the same origin on both stacks.
  uploadOrigin: k3d ? "https://s3.svp.localhost:8443" : "http://127.0.0.1:9000",
  sessionCookie: k3d ? "__Host-Http-svp_sid" : "svp_sid",
  secureCookie: k3d,
  // A browser trusts the system's roots only, and macOS keeps those in the Keychain, which a test run must not change:
  // so on k3d the browsers skip the certificate check. Node (the specs' own fetch) and curl (e2e/seed.sh) do check it,
  // against .k8s/ca.crt (NODE_EXTRA_CA_CERTS, CURL_CA_BUNDLE, set by e2e/k3d-e2e.sh). Contexts a spec makes itself with
  // browser.newContext() get none of the config's `use` options: they spread this.
  contextOptions: { ignoreHTTPSErrors: k3d },
} as const;
