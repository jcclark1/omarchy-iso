#!/bin/bash
#
# A headless ISO drops stock Arch rescue tools from the live package list. Each
# trimmed name must still be in releng's list (an upstream rename would make
# the trim silently stop working), and nothing the installer or hardware
# bring-up needs may be trimmed.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

eval "$(awk '/^live_trim_packages=\(/,/^\)/' "$ROOT/builder/build-network-install.sh")"
((${#live_trim_packages[@]} > 0)) || fail "trim list parsed"

releng="$ROOT/archiso/configs/releng/packages.x86_64"
if [[ -f $releng ]]; then
  for pkg in "${live_trim_packages[@]}"; do
    grep -qxF "$pkg" "$releng" || fail "$pkg is in releng's package list"
  done
else
  echo "  skip releng check: archiso submodule not checked out"
fi

for keep in lvm2 cryptsetup parted btrfs-progs qemu-guest-agent hyperv iwd openssh \
  archinstall arch-install-scripts linux-firmware wpa_supplicant brltty espeakup livecd-sounds zsh; do
  for pkg in "${live_trim_packages[@]}"; do
    [[ $pkg == "$keep" ]] && fail "$keep must stay in the live system"
  done
done

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
echo "  ok   live trim list (${#live_trim_packages[@]} packages)"
