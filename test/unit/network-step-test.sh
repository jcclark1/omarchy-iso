#!/bin/bash
#
# The configurator's server network step decides "online" by fetching the
# [core] database from the live pacman.conf's first online server, the same
# probe the orchestrator runs before pacstrap. Check it against the live conf
# a headless build generates (omarchy-local's file:// server comes first and
# must be skipped), and that the step is a no-op on a desktop ISO.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

configurator="$ROOT/configs/airootfs/root/configurator"
build="$ROOT/builder/build-network-install.sh"
eval "$(awk '/^core_db_url\(\) \{/,/^\}/' "$configurator")"
eval "$(awk '/^is_server_iso\(\) \{/,/^\}/' "$configurator")"
eval "$(awk "/^local_repo_section='/,/^'\$/" "$build")"
eval "$(awk '/^with_local_repo\(\) \{/,/^\}/' "$build")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for pair in stable:stable-mirror edge:mirror; do
  channel=${pair%%:*} host=${pair#*:}
  with_local_repo "$ROOT/configs/pacman-online-$channel.conf" >"$tmp/pacman.conf"
  check "$channel probe uses the snapshot mirror" \
    "https://$host.omarchy.org/core/os/x86_64/core.db" \
    "$(PACMAN_CONF="$tmp/pacman.conf" core_db_url)"
done

check "offline conf has no probe" "" "$(PACMAN_CONF="$ROOT/configs/pacman-offline.conf" core_db_url)"

echo server >"$tmp/profile"
ISO_PROFILE_MARKER="$tmp/profile" is_server_iso && server=yes || server=no
check "server marker enables the step" yes "$server"
echo desktop >"$tmp/profile"
ISO_PROFILE_MARKER="$tmp/profile" is_server_iso && server=yes || server=no
check "desktop ISO skips the step" no "$server"
ISO_PROFILE_MARKER="$tmp/missing" is_server_iso && server=yes || server=no
check "no marker skips the step" no "$server"

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
