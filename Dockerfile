FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# VERSION is injected from the build host (docker-compose passes
# `git describe --tags`); the .git dir is excluded from the build context
# so it cannot be derived here. Matches GoReleaser's -X main.version.
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -tags dashboard -ldflags "-s -w -X main.version=${VERSION}" -o /out/freebuff-proxy ./cmd/freebuff-proxy

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S -g 1000 app \
    && adduser -S -u 1000 -G app app \
    && mkdir -p /app/dump /app/logs \
    && chown -R app:app /app
WORKDIR /app
COPY --from=build /out/freebuff-proxy /usr/local/bin/freebuff-proxy
# Scaleway: PORT is injected at runtime (console Port param). Default 8080 for
# local docker. EXPOSE both legacy 3457 and Scaleway PORT. Binary falls back
# to $PORT when LISTEN_ADDR is default (see internal/config scaleway patch).
ENV PORT=8080
EXPOSE 3457 8080
USER app
ENTRYPOINT ["/usr/local/bin/freebuff-proxy"]
