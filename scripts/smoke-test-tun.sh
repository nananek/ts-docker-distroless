#!/usr/bin/env bash
# Smoke-test the TUN-capable image. Requires Docker. The runtime TUN test is
# skipped when the host does not expose /dev/net/tun.
set -euo pipefail

image="${1:?usage: smoke-test-tun.sh IMAGE}"
container=""

cleanup() {
  if [[ -n "$container" ]]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> netfilter binaries"
docker run --rm --entrypoint /usr/sbin/iptables "$image" -V
docker run --rm --entrypoint /usr/sbin/iptables-nft "$image" -V
docker run --rm --entrypoint /usr/sbin/iptables-legacy "$image" -V
docker run --rm --entrypoint /usr/sbin/ip "$image" -V

echo "==> no shell"
if docker run --rm --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1; then
  echo "unexpected shell in $image" >&2
  exit 1
fi

if [[ ! -e /dev/net/tun ]]; then
  echo "skip TUN runtime test: /dev/net/tun is not available"
  exit 0
fi

echo "==> TUN runtime"
container="$(
  docker run -d \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --device /dev/net/tun \
    --entrypoint /usr/local/bin/sandbox-exec \
    "$image" \
    /usr/local/bin/tailscaled \
      --tun=tailscale0 \
      --state=mem: \
      --statedir=/tmp \
      --socket=/tmp/tailscaled.sock \
      --port=0 \
      --no-logs-no-support
)"

for _ in $(seq 1 30); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]]; then
    echo "tailscaled exited during TUN startup" >&2
    docker logs "$container" >&2 || true
    exit 1
  fi
  if docker exec "$container" /usr/sbin/ip link show tailscale0 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "$container" /usr/sbin/ip link show tailscale0

# The two netfilter backends need different things from the host kernel. The
# legacy (xtables) nat table is a kernel module that only the host can load --
# a container has no modprobe -- so on a host that has never used legacy
# iptables (e.g. a Docker host on the nft backend) it may be absent. The nft
# backend uses the nf_tables subsystem those hosts do have. tailscaled picks a
# backend at runtime, so the image only has to be able to program the nat table
# through at least one of them.
nat_backend=""
nat_error="$(mktemp)"
for backend in iptables-nft iptables-legacy; do
  if docker exec "$container" "/usr/sbin/$backend" -t nat -L -n >/dev/null 2>"$nat_error"; then
    echo "nat table: $backend"
    nat_backend="$backend"
    break
  fi
done
rm -f "$nat_error"
if [[ -z "$nat_backend" ]]; then
  echo "neither iptables-nft nor iptables-legacy can list the nat table" >&2
  docker exec "$container" /usr/sbin/iptables-nft -t nat -L -n >&2 || true
  docker exec "$container" /usr/sbin/iptables-legacy -t nat -L -n >&2 || true
  exit 1
fi

docker exec "$container" /usr/local/bin/tailscale --socket=/tmp/tailscaled.sock status >/dev/null 2>&1 || true

echo "TUN smoke test OK"
