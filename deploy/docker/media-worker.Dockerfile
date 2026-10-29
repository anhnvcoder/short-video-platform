# media-worker image: the Go build of
# service.Dockerfile, on an Alpine runtime that carries ffmpeg and ffprobe. Distroless has no
# ffmpeg, so this image has a shell and apk; compose makes up for it (read-only root, no
# capabilities, non-root user, no internet). No secret goes into the build: credentials are
# environment variables given at run time.
# No `# syntax=` line: BuildKit's built-in frontend already runs RUN --mount, and a syntax image would be pulled
# from Docker Hub by a tag that can be pushed again, the one unpinned image of the build.

# Build stage: the Go release named by the go directive of go.mod (make vulncheck fails when they differ). Base images
# are pinned by the digest of their multi-arch index (linux/amd64 and linux/arm64), as in service.Dockerfile: a tag can
# be pushed again with other content, a digest cannot.
FROM golang:1.27.3-trixie@sha256:7b072c590a326b9d2a43b165ae247f6e8eafff32e1ad154ab97139e89f053be9 AS build
WORKDIR /src

# Modules first, so the download layer is reused until go.mod or go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Only the code the worker can import: generated proto code, shared internal/ and its own tree.
COPY gen/ gen/
COPY internal/ internal/
COPY services/media-worker/ services/media-worker/
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /app ./services/media-worker/cmd/media-worker

# Runtime stage: the tag keeps the 3.24 branch; the ffmpeg package is not pinned, since Alpine
# drops old builds from its repository once a fix lands, so a rebuild takes the branch's patches. The base itself is
# pinned by digest; Renovate proposes the next 3.24 build.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache ffmpeg \
    && install -d -o 65532 -g 65532 -m 0750 /work
COPY --from=build /app /app
USER 65532:65532
ENTRYPOINT ["/app"]
