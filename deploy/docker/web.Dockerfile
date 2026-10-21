# Image of the web client (docs/adr/0016-web-client.md, sections 1, 7 and 10): Next's standalone server on the
# distroless Node runtime. Build context is web/ (its .dockerignore leaves out node_modules, build output and .env*):
#   env -u DOCKER_DEFAULT_PLATFORM docker build -f deploy/docker/web.Dockerfile -t svp/web:dev web
# No secret and no runtime setting goes into the build: GATEWAY_URL, REDIS_URL, APP_ORIGIN and MEDIA_ORIGIN are read
# by the server when a request needs them, so one image runs in compose and in the cluster.
# No `# syntax=` line, as in service.Dockerfile: BuildKit's built-in frontend runs RUN --mount, and a syntax image
# would be one more image pulled by a tag.

# Build stage. Every base image is pinned by the digest of its multi-arch index (linux/amd64 and linux/arm64), so the
# same commit builds from the same base on the machine and in CI, and Renovate proposes each new digest as a reviewed
# change (docs/adr/0015-cicd-devsecops-stage5.md, sections 4 and 10). The Node major (26, also in the runtime image's
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

# next build writes source maps of the server's route bundles; they never reach the browser, but the image ships no
# source map at all.
COPY . .
RUN pnpm build && find .next/standalone .next/static -name '*.map' -delete

# Runtime stage: Node, CA certificates, tzdata and the nonroot user (uid 65532); no shell, no package manager, no npm,
# so the compose healthcheck runs node itself. The nonroot tag follows each distroless rebuild; the digest fixes the
# content. The Node major is part of the image name, which Renovate never changes: moving to Node 27 means editing this
# name by hand to nodejs27-debian13 in the same pull request.
FROM gcr.io/distroless/nodejs26-debian13:nonroot@sha256:b093852cde840e6f7ab2c2081adfbdb81810a340e06a2869fdc4ed31354c9d9e
WORKDIR /app
ENV NODE_ENV=production \
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
