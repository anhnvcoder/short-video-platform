# syntax=docker/dockerfile:1
# One Dockerfile for every Go service; pick it with --build-arg SERVICE=<directory under services/>
# (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 7). No secret goes into the
# build: configuration and keys are environment variables given at run time.

# Build stage: Go toolchain pinned to the version the repo is developed with.
FROM golang:1.27.2-trixie AS build
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
# manager, so the healthcheck is a subcommand of the binary itself.
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
