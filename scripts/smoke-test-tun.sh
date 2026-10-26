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
docker exec "$container" /usr/sbin/iptables -t nat -L -n >/dev/null
docker exec "$container" /usr/local/bin/tailscale --socket=/tmp/tailscaled.sock status >/dev/null 2>&1 || true

echo "TUN smoke test OK"
