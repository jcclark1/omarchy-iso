#!/bin/bash
#
# The headless (server profile) tail of build-iso.sh, sourced in place of its
# offline-mirror section. A headless ISO is a network install: it carries no
# offline mirror, only omarchy-local, a tiny repo of the packages built from the
# local checkouts (they exist in no online repo). Everything else comes from the
# channel's online repos at install time, the same mirrors the installed server
# uses afterwards, which keeps the ISO far below GitHub's 2 GB release limit.
#
# Expects from build-iso.sh: build_cache_dir, local_repo_dir, OMARCHY_MIRROR,
# the OMARCHY_*_PACKAGE targets and the shipped server manifest. Ends the build.

online_pacman_conf="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
build_pacman_conf="$build_cache_dir/pacman-network-build.conf"
live_pacman_conf="$build_cache_dir/airootfs/etc/pacman.conf"
local_packages=("$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE")

# The local build emits both halves of each split recipe (omarchy-dev beside
# omarchy-server-dev). Keep exactly one file per selected package name.
keep_files=()
for local_package_name in "${local_packages[@]}"; do
  local_package_file=""
  for candidate in "$local_repo_dir/$local_package_name-"*.pkg.tar.*; do
    [[ -f $candidate && $candidate != *.sig ]] || continue
    read -r candidate_name _ < <(pacman -Qp "$candidate" 2>/dev/null) || continue
    [[ $candidate_name == "$local_package_name" ]] || continue
    if [[ -n $local_package_file ]]; then
      echo "ERROR: multiple local builds found for $local_package_name" >&2
      exit 1
    fi
    local_package_file="${candidate##*/}"
  done
  if [[ -z $local_package_file ]]; then
    echo "ERROR: local build not found for $local_package_name" >&2
    exit 1
  fi
  keep_files+=("$local_package_file")
done
printf '%s\n' "${keep_files[@]}" | bash /builder/prune-offline-mirror.sh "$local_repo_dir"

rm -f "$local_repo_dir"/omarchy-local.db* "$local_repo_dir"/omarchy-local.files*
repo-add "$local_repo_dir/omarchy-local.db.tar.gz" "$local_repo_dir/"*.pkg.tar.zst

# The file:// server below must resolve inside this container too, for mkarchiso
# and the package count; symlink rather than duplicate.
mkdir -p /var/cache/omarchy/mirror
ln -sfn "$local_repo_dir" /var/cache/omarchy/mirror/local

# omarchy-local goes first so its builds win over any same-named package the
# online [omarchy] repo publishes. SigLevel = Never for the same reason the
# desktop's [offline] repo uses it: local builds are unsigned, and the repo
# ships inside the ISO, whose integrity the airootfs checksum already covers.
local_repo_section='[omarchy-local]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/local/
'
with_local_repo() {
  awk -v section="$local_repo_section" '
    !inserted && /^\[/ && !/^\[options\]/ { print section; inserted = 1 }
    { print }
  ' "$1"
}

without_repo() {
  awk -v repo="[$1]" '/^\[/ { skip = ($0 == repo) } !skip'
}

# mkarchiso builds the live system from the online repos plus omarchy-local
# (the live system needs the locally built omarchy-settings package), and keeps
# [arch-mact2] for the linux-t2 kernel the live ISO boots.
with_local_repo "$online_pacman_conf" >"$build_pacman_conf"
sed -i 's/^pacman_conf=.*/pacman_conf="pacman-network-build.conf"/' "$build_cache_dir/profiledef.sh"
sed -i 's|var/cache/omarchy/mirror/offline|var/cache/omarchy/mirror/local|g' "$build_cache_dir/profiledef.sh"

# The live system's pacman.conf is what pacstrap installs the target from. The
# online conf carries no NoExtract rules, which would otherwise leak into the
# target's files. [arch-mact2] is unsigned and serves only the live kernel, so
# it stays out of the install.
with_local_repo "$online_pacman_conf" |
  without_repo arch-mact2 >"$live_pacman_conf"

# Denominator for the install dashboard's progress bar: the target set resolved
# against the live pacman.conf, as pacstrap will at install time. The online
# repos move between build and install, so this is an estimate; the dashboard
# only needs a denominator and falls back to its time-based curve without one.
resolve_expected_packages() {
  local resolve_root=/tmp/omarchy-expected-packages
  local resolved
  local -a targets

  rm -rf "$resolve_root"
  mkdir -p "$resolve_root/var/lib/pacman"

  mapfile -t targets < <(
    {
      grep -hv '^#\|^$' /builder/archinstall.packages
      grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-server.packages"
      printf '%s\n' "${local_packages[@]}"
    } | sort -u
  )

  pacman --config "$live_pacman_conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -Sy >/dev/null || return 1

  resolved="$(pacman --config "$live_pacman_conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' "${targets[@]}")" || return 1

  printf '%s\n' "$resolved" | sort -u | grep -c .
}

# A target missing from the online repos would fail pacstrap the same way, so
# that fails the build.
if ! expected_packages="$(resolve_expected_packages)"; then
  echo "ERROR: could not resolve the server install set against the online repos." >&2
  echo "       pacstrap would fail the same way at install time." >&2
  exit 1
fi
if ((expected_packages < 200 || expected_packages > 2000)); then
  echo "WARNING: resolved target package count $expected_packages is outside the" >&2
  echo "         expected 200-2000 range; shipping no denominator so the install" >&2
  echo "         dashboard falls back to its time-based curve." >&2
else
  printf '%s\n' "$expected_packages" \
    >"$build_cache_dir/airootfs/usr/share/omarchy-iso/expected-packages"
  echo "Target install resolves to $expected_packages packages."
fi

mkarchiso -v -w "$build_cache_dir/work/" -o /out/ "$build_cache_dir/"

if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" /out/
fi

exit 0
