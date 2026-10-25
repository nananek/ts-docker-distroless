# syntax=docker/dockerfile:1.7

# Tailscale has no moving "nightly" tag. Nightly builds from main are published
# as ghcr.io/tailscale/tailscale:unstable-vX.Y.Z (the moving ":unstable" tag can
# lag behind them). The nightly workflow resolves the newest versioned tag and
# passes it here. There is deliberately no default: a local build must choose a
# tag or it fails instead of silently using an old Tailscale.
ARG TAILSCALE_IMAGE

# Pinned by digest so that a rebuild does not silently pick up a different
# distroless. The plain "static" image tracks the current Debian release
# (bookworm, trixie, ...); the binaries in this image are all static Go, so the
# Debian version does not matter. Only the digest is pinned.
ARG DISTROLESS_IMAGE=gcr.io/distroless/static@sha256:15f8637509792e05b97d83451b0b6ccfa4abd548f997e406ac1e72c87fe1fa78

ARG GOLANG_IMAGE=golang:1.27-alpine

# The upstream image is Alpine, but the three tailscale binaries are static
# Go binaries. Only they are copied into the final image.
FROM ${TAILSCALE_IMAGE} AS upstream

# sandbox-exec installs a small seccomp denylist before exec'ing containerboot.
# Building it here keeps the final image free of a toolchain and a shell.
FROM ${GOLANG_IMAGE} AS sandbox-exec
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
WORKDIR /src
COPY cmd/sandbox-exec/go.mod cmd/sandbox-exec/go.sum ./
RUN go mod download
COPY cmd/sandbox-exec/ ./
RUN set -eu; \
    case "${TARGETARCH}" in \
      arm) export GOARM="${TARGETVARIANT#v}" ;; \
      *) unset GOARM ;; \
    esac; \
    CGO_ENABLED=0 GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH}" \
      go build -trimpath -ldflags="-s -w" -o /out/sandbox-exec .; \
    mkdir -p /out/rootfs/var/lib/tailscale /out/rootfs/var/run/tailscale

FROM ${DISTROLESS_IMAGE}

ARG TAILSCALE_IMAGE
ARG DISTROLESS_IMAGE

LABEL org.opencontainers.image.title="tailscale-distroless" \
      org.opencontainers.image.description="Tailscale nightly on distroless/static; Tailscale SSH is disabled by seccomp" \
      org.opencontainers.image.licenses="BSD-3-Clause" \
      org.opencontainers.image.base.name="${DISTROLESS_IMAGE}" \
      org.opencontainers.image.version="${TAILSCALE_IMAGE}"

# containerboot defaults to userspace networking. This image has no iptables
# or iproute2, so kernel/TUN mode is not supported.
ENV TS_USERSPACE=true \
    TS_STATE_DIR=/var/lib/tailscale

COPY --from=upstream \
     /usr/local/bin/tailscale \
     /usr/local/bin/tailscaled \
     /usr/local/bin/containerboot \
     /usr/local/bin/

COPY --from=sandbox-exec /out/sandbox-exec /usr/local/bin/sandbox-exec
COPY --from=sandbox-exec /out/rootfs/var /var

# Kept for reference and for runtimes that accept a profile path. The image
# itself is already protected by sandbox-exec; applying this profile adds the
# full allowlist.
COPY --chown=0:0 seccomp/tailscale.json /etc/tailscale/seccomp.json

# tailscaled needs root: it owns its state, the local API socket and, in
# tailscaled's non-userspace modes, the network configuration. nonroot is not
# supported.
USER 0:0

ENTRYPOINT ["/usr/local/bin/sandbox-exec", "/usr/local/bin/containerboot"]
