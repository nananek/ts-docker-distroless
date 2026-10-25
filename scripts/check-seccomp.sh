#!/usr/bin/env bash
# Validate the checked-in seccomp profile without a container runtime.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$repo_root/seccomp/tailscale.json"
blocklist="$repo_root/seccomp/blocklist.txt"

jq empty "$profile"
jq -e '.defaultAction == "SCMP_ACT_ERRNO"' "$profile" >/dev/null
jq -e '.defaultErrnoRet == 1' "$profile" >/dev/null
jq -e '.archMap | length > 0' "$profile" >/dev/null
jq -e 'all(.syscalls[]; (.names | length) > 0)' "$profile" >/dev/null

allowed="$(jq -r '.syscalls[] | select(.action == "SCMP_ACT_ALLOW") | .names[]' "$profile")"

status=0
entries=0
while IFS= read -r name; do
  case "$name" in
    ""|\#*) continue ;;
  esac
  entries=$((entries + 1))
  if grep -Fxq -- "$name" <<<"$allowed"; then
    echo "seccomp: $name is still allowed by $profile" >&2
    status=1
  fi
done < "$blocklist"

if (( status != 0 )); then
  exit 1
fi

# runc calls these in setupUser() before installing the profile when
# no-new-privileges is off. Keeping them allowed is what makes the profile safe
# to apply without extra flags; sandbox-exec blocks them after runc instead.
for required in setgroups setgroups32 setgid setgid32 setuid setuid32; do
  if ! grep -Fxq -- "$required" <<<"$allowed"; then
    echo "seccomp: $required must stay allowed (runc setupUser)" >&2
    status=1
  fi
done

if (( status != 0 )); then
  exit 1
fi

echo "seccomp profile OK: $entries blocklist entries, none allowed"
