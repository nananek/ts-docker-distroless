#!/usr/bin/env bash
# Print the newest Tailscale nightly (unstable) image tag.
#
# Tailscale builds main every night and publishes it as
# ghcr.io/tailscale/tailscale:unstable-vX.Y.Z. The moving ":unstable" tag is
# not used because it can lag behind the versioned tags.
set -euo pipefail

image_repo="${TAILSCALE_IMAGE_REPO:-tailscale/tailscale}"

if [[ -n "${TAILSCALE_TAG:-}" ]]; then
  printf '%s\n' "$TAILSCALE_TAG"
  exit 0
fi

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

token="$(
  curl -fsSL \
    "https://ghcr.io/token?scope=repository:${image_repo}:pull&service=ghcr.io" |
    jq -r '.token'
)"

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "failed to obtain an anonymous GHCR token for ${image_repo}" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
: >"$tmpdir/tags"

url="https://ghcr.io/v2/${image_repo}/tags/list?n=1000"
while [[ -n "$url" ]]; do
  curl -fsSL \
    -D "$tmpdir/headers" \
    -H "Authorization: Bearer ${token}" \
    "$url" -o "$tmpdir/body"

  jq -r '.tags[]?' "$tmpdir/body" >>"$tmpdir/tags"

  link="$(
    grep -i '^link:' "$tmpdir/headers" 2>/dev/null | tr -d '\r' || true
  )"
  url=""
  link_re='<([^>]+)>[^,]*rel="next"'
  if [[ "$link" =~ $link_re ]]; then
    url="${BASH_REMATCH[1]}"
    if [[ "$url" != http* ]]; then
      url="https://ghcr.io${url}"
    fi
  fi
done

tag="$(
  grep -E '^unstable-v[0-9]+\.[0-9]+\.[0-9]+$' "$tmpdir/tags" |
    sort -V |
    tail -n 1
)"

if [[ -z "$tag" ]]; then
  echo "no unstable-vX.Y.Z tag found for ${image_repo}" >&2
  exit 1
fi

printf '%s\n' "$tag"
