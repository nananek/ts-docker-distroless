#!/usr/bin/env bash
# Regenerate seccomp/tailscale.json from the Moby default seccomp profile with
# the syscalls in seccomp/blocklist.txt removed.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$repo_root/seccomp/tailscale.json"
blocklist="$repo_root/seccomp/blocklist.txt"

# Pinned so that regenerating is reproducible. Bump deliberately and review
# the diff; see https://github.com/moby/profiles/commits/main/seccomp/default.json
moby_profiles_rev="${MOBY_PROFILES_REV:-6fe7deb1b9fb7c0397a4593480d7d22b9ee8caef}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL \
  "https://raw.githubusercontent.com/moby/profiles/${moby_profiles_rev}/seccomp/default.json" \
  -o "$tmp"

blocked_json="$(grep -vE '^[[:space:]]*(#|$)' "$blocklist" | jq -R . | jq -s .)"

jq \
  --argjson blocked "$blocked_json" \
  '
    .syscalls |= map(
      if .action == "SCMP_ACT_ALLOW"
      then .names |= map(select(. as $name | $blocked | index($name) | not))
      else . end
    )
    | .syscalls |= map(select((.names | length) > 0))
  ' "$tmp" > "$profile"

echo "wrote $profile"
