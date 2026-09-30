#!/bin/bash
#
# A headless ISO installs from the network. Its live pacman.conf, which pacstrap
# installs the target from, must list omarchy-local ahead of every online repo
# (its local builds win over published ones) and must leave out [arch-mact2],
# the unsigned repo that only serves the live kernel. The build-time conf keeps
# it, since mkarchiso installs that kernel.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s:\n    expected: %s\n    got:      %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

script="$ROOT/builder/build-network-install.sh"
eval "$(awk "/^local_repo_section='/,/^'\$/" "$script")"
eval "$(awk '/^with_local_repo\(\) \{/,/^\}/' "$script")"
eval "$(awk '/^without_repo\(\) \{/,/^\}/' "$script")"

sections() { grep '^\[' | paste -sd' '; }

for channel in stable edge rc; do
  online="$ROOT/configs/pacman-online-$channel.conf"
  build=$(with_local_repo "$online")
  live=$(with_local_repo "$online" | without_repo arch-mact2)

  check "$channel build conf repos" \
    "[options] [omarchy-local] [core] [extra] [multilib] [omarchy] [arch-mact2]" \
    "$(sections <<<"$build")"
  check "$channel live conf repos" \
    "[options] [omarchy-local] [core] [extra] [multilib] [omarchy]" \
    "$(sections <<<"$live")"
  check "$channel live conf keeps the online servers" \
    "$(grep -c '^Server = https' "$online" | awk '{print $1 - 2}')" \
    "$(grep -c '^Server = https' <<<"$live")"
  check "$channel local repo is file:// and unsigned" \
    "SigLevel = Never|Server = file:///var/cache/omarchy/mirror/local/" \
    "$(awk '/^\[omarchy-local\]/{f=1;next} /^\[/{f=0} f && NF' <<<"$live" | paste -sd'|')"
  check "$channel live conf has no NoExtract" "0" "$(grep -c '^NoExtract' <<<"$live")"
done

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
