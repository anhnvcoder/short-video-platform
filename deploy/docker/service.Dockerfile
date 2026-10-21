# One Dockerfile for every Go service, so the toolchain pin, static build and distroless runtime are defined once; pick
# the service with --build-arg SERVICE=<directory under services/>
# (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7). No secret goes into the
# build: configuration and keys are environment variables given at run time.
# No `# syntax=` line: BuildKit's built-in frontend already runs RUN --mount, and a syntax image would be pulled
# from Docker Hub by a tag that can be pushed again, the one unpinned image of the build.

# Build stage: Go toolchain pinned to the version the repo is developed with. Every base image is pinned by the digest
# of its multi-arch index (linux/amd64 and linux/arm64): a tag can be pushed again with other content, a digest cannot,
# so the same commit builds from the same base on the machine and in CI, and Renovate proposes each new digest as a
# reviewed change (docs/adr/0015-cicd-devsecops-stage5.md, section 4).
FROM golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e AS build
ARG SERVICE
WORKDIR /src

# Modules first, so the download layer is reused until go.mod or go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Only the code the service can import: generated proto code, shared internal/ and its own tree.
COPY gen/ gen/
COPY internal/ internal/
COPY services/${SERVICE}/ services/${SERVICE}/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /app ./services/${SERVICE}/cmd/${SERVICE}

# Runtime stage: CA certificates, tzdata and the nonroot user (uid 65532); no shell, no package
# manager, so the healthcheck is a subcommand of the binary itself. The nonroot tag follows each distroless rebuild;
# the digest fixes the content.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:516757106de35205efb70b91ba03f6f1298424a0678c603255cf2852a7000087
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
