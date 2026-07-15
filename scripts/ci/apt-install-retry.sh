#!/usr/bin/env bash
# CI apt install with the two failure modes we've actually hit on GitHub
# arm64 runners baked in:
#   1. no IPv6 route to ports.ubuntu.com  -> force IPv4 (+ transfer retries)
#   2. 404 on a .deb the index still lists -> the mirror pruned a superseded
#      version mid-run; a fresh `apt-get update` + retry resolves it
# Usage: scripts/ci/apt-install-retry.sh <package> [<package>...]
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <package> [<package>...]" >&2
  exit 2
fi

echo 'Acquire::ForceIPv4 "true"; Acquire::Retries "3";' \
  | sudo tee /etc/apt/apt.conf.d/99-fae-ci-ipv4 >/dev/null

for attempt in 1 2 3; do
  if sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends "$@"; then
    exit 0
  fi
  echo "apt install failed (attempt ${attempt}/3) — refreshing index and retrying in 15s" >&2
  sleep 15
done

echo "apt install failed after 3 attempts" >&2
exit 1
