#!/bin/bash
#
# A headless (server profile) build must install the server split of the
# Omarchy runtime. The desktop runtime hard-depends on hyprland, sddm,
# pipewire, ..., none of which the server offline mirror carries, so picking
# it fails the build's package resolution (and would fail pacstrap). The
# server packages are split packages of the desktop recipes, so a local-source
# build must find them in those directories.

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

# The package selection block at the top of build-iso.sh, run on its own.
selection=$(awk '/^OMARCHY_ISO_REF=/,/^export OMARCHY_RUNTIME_PACKAGE/' "$ROOT/builder/build-iso.sh")

runtime_for() {
  env -u OMARCHY_RUNTIME_PACKAGE -u OMARCHY_SETTINGS_PACKAGE "$@" \
    bash -c "$selection"$'\n''echo "$OMARCHY_RUNTIME_PACKAGE"'
}

check "desktop stable runtime" omarchy "$(runtime_for OMARCHY_ISO_REF=quattro OMARCHY_PROFILE=desktop)"
check "desktop local runtime" omarchy-dev "$(runtime_for OMARCHY_ISO_REF=local OMARCHY_PROFILE=desktop)"
check "server stable runtime" omarchy-server "$(runtime_for OMARCHY_ISO_REF=quattro OMARCHY_PROFILE=server)"
check "server local runtime" omarchy-server-dev "$(runtime_for OMARCHY_ISO_REF=local OMARCHY_PROFILE=server)"
check "explicit runtime wins on server" custom "$(runtime_for OMARCHY_ISO_REF=local OMARCHY_PROFILE=server OMARCHY_RUNTIME_PACKAGE=custom)"

# build-omarchy-packages.sh maps each package to the recipe that builds it.
eval "$(awk '/^pkgbuild_dir\(\) \{/,/^\}/' "$ROOT/builder/build-omarchy-packages.sh")"

check "server-dev builds from omarchy-dev" omarchy-dev "$(pkgbuild_dir omarchy-server-dev)"
check "server builds from omarchy" omarchy "$(pkgbuild_dir omarchy-server)"
check "dev builds from its own recipe" omarchy-dev "$(pkgbuild_dir omarchy-dev)"
check "settings-dev builds from its own recipe" omarchy-settings-dev "$(pkgbuild_dir omarchy-settings-dev)"
check "nvim builds from its own recipe" omarchy-nvim "$(pkgbuild_dir omarchy-nvim)"

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
