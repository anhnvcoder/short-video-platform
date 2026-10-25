# Image of the web client: Next's standalone server on the
# distroless Node runtime. Build context is web/ (its .dockerignore leaves out node_modules, build output and .env*):
#   env -u DOCKER_DEFAULT_PLATFORM docker build -f deploy/docker/web.Dockerfile -t svp/web:dev web
# No secret and no runtime setting goes into the build: GATEWAY_URL, REDIS_URL, APP_ORIGIN, MEDIA_ORIGIN, UPLOAD_ORIGIN,
# SENTRY_DSN, SENTRY_ENVIRONMENT, NEXT_SERVER_ACTIONS_ENCRYPTION_KEY and the OTEL_* variables of the OpenTelemetry SDK are
# read by the server when it starts or when a request needs them, so one image runs in compose and in the cluster. The
# one build argument, SVP_BUILD_ID, is the build's id, not a setting (below).
# The browser bundle's source maps are left out of the image; the stage `sourcemaps` holds them, from the same build:
#   env -u DOCKER_DEFAULT_PLATFORM docker build -f deploy/docker/web.Dockerfile --target sourcemaps \
#     --output type=local,dest=<directory> web
# No `# syntax=` line, as in service.Dockerfile: BuildKit's built-in frontend runs RUN --mount, and a syntax image
# would be one more image pulled by a tag.

# Build stage. Every base image is pinned by the digest of its multi-arch index (linux/amd64 and linux/arm64), so the
# same commit builds from the same base on the machine and in CI, and Renovate proposes each new digest as a reviewed
# change. The Node major (26, also in the runtime image's
# name below) moves with web/.nvmrc and engines of web/package.json in one Renovate pull request.
FROM node:26-trixie@sha256:31ea2a1880e8393df2445e7654ec74992d7fa450fd659ba5b66b0bec909a55b1 AS build
WORKDIR /src
ENV NEXT_TELEMETRY_DISABLED=1

# Node 25 and later ship without Corepack: pnpm is installed with npm, at the exact version of the packageManager
# field of package.json, the one place that pins it (the dev machine and CI install it the same way). npm runs a
# package's install scripts by default; pnpm works without its preinstall and postinstall, so --ignore-scripts keeps
# them from running in the build.
COPY package.json ./
RUN npm install -g --ignore-scripts "pnpm@$(node -p 'require("./package.json").packageManager.split("@")[1]')"

# The manifests before the sources, so the install layer is reused until a dependency or a pnpm setting changes; the
# store is a build cache, never part of the image. --frozen-lockfile fails instead of resolving anew, and
# pnpm-workspace.yaml brings the install rules (minimumReleaseAge, strictDepBuilds, trustPolicy, no sharp).
COPY pnpm-lock.yaml pnpm-workspace.yaml ./
RUN --mount=type=cache,target=/pnpm-store pnpm install --frozen-lockfile --store-dir /pnpm-store

COPY . .
# The build's id: the first 12 hex digits of the commit
# in CI (deploy/ci/build-image.sh), dev- and a hash of this build context on the dev path of k3d (web_build_id of
# deploy/k8s/lib.sh), empty for compose. next.config.ts makes it Next's deploymentId. Declared here, after the install,
# so a new id rebuilds from this step on and keeps the install layer.
ARG SVP_BUILD_ID=
# Source maps (section 9): next build writes one beside each browser chunk and stylesheet, each file ending with a
# sourceMappingURL comment that names its map (a hashed name of its own), and maps of the server's bundles in the
# standalone tree. A served map would publish the whole client source, so:
#   - every map of .next/static moves to /sourcemaps/_next/static (the path the browser fetches the chunk from), with a
#     copy of each JavaScript chunk that names a map: the chunk as built, whose comment pairs it with its map for the
#     upload (make web-sourcemaps), and whose debug id is the one the served chunk carries;
#   - the served chunks and stylesheets lose that comment (a "hidden" map: the bundle names none), which is their last
#     line, so every other line and column, and the debug id comment, stay what the map describes;
#   - the server's maps are deleted, as before.
# The checks after fail the build when a map, or the word sourceMappingURL in any form, is left for the runtime stage.
# The build and the moves are two steps of this stage only: the runtime stage below copies the result, never the
# layers, so no map reaches the image.
RUN pnpm build
WORKDIR /src/.next
RUN mkdir -p /sourcemaps/_next && \
    find static -name '*.map' -exec sh -c 'mkdir -p "/sourcemaps/_next/${1%/*}" && mv "$1" "/sourcemaps/_next/$1"' _ {} \; && \
    grep -rlE --include='*.js' '^//# sourceMappingURL=' static | \
      xargs -r -I{} sh -c 'mkdir -p "/sourcemaps/_next/${1%/*}" && cp "$1" "/sourcemaps/_next/$1"' _ {} && \
    find static -name '*.js' -exec sed -i '/^\/\/# sourceMappingURL=/d' {} + && \
    find static -name '*.css' -exec sed -i '/^\/\*# sourceMappingURL=.*\*\/$/d' {} + && \
    find standalone -name '*.map' -delete && \
    if [ -n "$(find static standalone -name '*.map')" ]; then echo "a source map is left for the image" >&2; exit 1; fi && \
    if grep -rq 'sourceMappingURL' static; then echo "a served file still names a source map" >&2; exit 1; fi && \
    if [ -z "$(find /sourcemaps -name '*.js.map')" ]; then echo "next build wrote no browser source map" >&2; exit 1; fi

# The browser bundle's maps and their chunks, alone: built only when asked for (--target sourcemaps). Cached like the
# rest, so with the same context and build argument it holds the maps of the very bundle the image serves; a build
# without cache would make another bundle (Server Action ids are random per build).
FROM scratch AS sourcemaps
COPY --from=build /sourcemaps/ /

# Runtime stage: Node, CA certificates, tzdata and the nonroot user (uid 65532); no shell, no package manager, no npm,
# so the compose healthcheck runs node itself. The nonroot tag follows each distroless rebuild; the digest fixes the
# content. The Node major is part of the image name, which Renovate never changes: moving to Node 27 means editing this
# name by hand to nodejs27-debian13 in the same pull request.
FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:b093852cde840e6f7ab2c2081adfbdb81810a340e06a2869fdc4ed31354c9d9e
WORKDIR /app
# The build's id again, for the server: the release of its GlitchTip events and service.version of its telemetry; empty
# means none.
ARG SVP_BUILD_ID=
ENV SVP_BUILD_ID=$SVP_BUILD_ID \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0 \
    PORT=3001
# Only the standalone server (server.js and the node_modules it really uses) and the browser assets it serves; the app
# has no public/ directory. Files stay owned by root, so the server cannot rewrite its own code.
COPY --from=build /src/.next/standalone ./
COPY --from=build /src/.next/static ./.next/static
USER nonroot:nonroot
EXPOSE 3001
# The image's entrypoint is node.
CMD ["server.js"]
