#!/usr/bin/env bash
# Smoke-test a built image. Requires Docker.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:?usage: smoke-test.sh IMAGE}"
seccomp_profile="$repo_root/seccomp/tailscale.json"
probe_image="ts-distroless-seccomp-probe:test"
container=""

cleanup() {
  if [[ -n "$container" ]]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> binaries"
docker run --rm --entrypoint /usr/local/bin/tailscale "$image" version
docker run --rm --entrypoint /usr/local/bin/tailscaled "$image" --version

echo "==> no shell"
if docker run --rm --entrypoint /bin/sh "$image" -c true >/dev/null 2>&1; then
  echo "unexpected shell in $image" >&2
  exit 1
fi

echo "==> entrypoint"
entrypoint="$(docker inspect -f '{{json .Config.Entrypoint}}' "$image")"
grep -q 'sandbox-exec' <<<"$entrypoint" || {
  echo "sandbox-exec is not the entrypoint: $entrypoint" >&2
  exit 1
}

echo "==> probe image"
docker build \
  --build-arg "BASE=$image" \
  -t "$probe_image" \
  "$repo_root/test/probe"

# Without either filter, the probe can drop privileges. This also proves that
# the probe is actually testing something.
if docker run --rm \
  --entrypoint /probe \
  -e PROBE_MODE=ssh \
  --cap-add=SETUID --cap-add=SETGID \
  "$probe_image" >/dev/null 2>&1; then
  echo "probe unexpectedly passed without a filter" >&2
  exit 1
fi

echo "==> seccomp profile"
# The profile intentionally leaves setgroups/setgid/setuid alone: runc calls
# them during setupUser() and may install the profile before that happens.
docker run --rm \
  --entrypoint /probe \
  -e PROBE_MODE=profile \
  --security-opt "seccomp=$seccomp_profile" \
  "$probe_image"

echo "==> built-in filter"
# sandbox-exec runs after runc, so it can block the SSH privilege-drop
# syscalls without breaking container startup.
docker run --rm -e PROBE_MODE=ssh "$probe_image"

echo "==> tailscaled startup"
# Start tailscaled directly (still through sandbox-exec) so the test does not
# depend on a Tailscale auth key or the control plane.
container="$(
  docker run -d \
    --entrypoint /usr/local/bin/sandbox-exec \
    --security-opt "seccomp=$seccomp_profile" \
    "$image" \
    /usr/local/bin/tailscaled \
      --tun=userspace-networking \
      --state=mem: \
      --statedir=/tmp \
      --socket=/tmp/tailscaled.sock \
      --port=0 \
      --no-logs-no-support
)"

status=""
for _ in $(seq 1 30); do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]]; then
    echo "tailscaled exited before becoming ready" >&2
    docker logs "$container" >&2 || true
    exit 1
  fi
  status="$(docker exec "$container" /usr/local/bin/tailscale --socket=/tmp/tailscaled.sock status 2>&1 || true)"
  if grep -q 'Logged out' <<<"$status"; then
    break
  fi
  sleep 1
done

docker logs "$container" >&2 || true
grep -q 'Logged out' <<<"$status" || {
  echo "tailscaled did not answer the local API: $status" >&2
  exit 1
}

echo "smoke test OK"
