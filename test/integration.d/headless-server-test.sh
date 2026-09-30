#!/bin/bash
#
# Headless server profile: proves a --headless ISO installs a console-only
# Omarchy server. Boots the installed base and asserts it came up on the
# server profile: multi-user.target with tty1 autologin instead of a display
# manager, a verbose boot with no Plymouth splash, SSH enabled and let through the firewall, the stock kernel (the
# cidata config asks for linux-omarchy, which the server install coerces),
# the CLI/dev core installed with no desktop stack, packages installed from
# the network (no offline mirror, ISO under the release size gate) over a
# static connection carried to the installed server, and the
# mise wrappers ("delayed packages") resolving on first use.
#
# Skips on a desktop base, so the default suite stays green for either ISO.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }
skip_unless_profile server

# Login shells, so ~/.local/bin (the mise wrappers) is on PATH as it is for
# a person who SSHes in.
ssh_login() {
  ssh_guest "bash -lc $(printf %q "$1")"
}

log "Booting headless server from base image overlay"
start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
capture_console "success-console"

# --- profile and boot target ---

check "the installed profile marker is server" \
  ssh_guest "[[ \$(cat /etc/omarchy/profile) == server ]]"
check "boots to multi-user.target" \
  ssh_guest "[[ \$(systemctl get-default) == multi-user.target ]]"
check "no display manager is enabled" \
  ssh_guest "! systemctl is-enabled display-manager.service"
check "tty1 autologins the install user" \
  ssh_guest "grep -q -- '--autologin $GUEST_USER' /etc/systemd/system/getty@tty1.service.d/autologin.conf"
check "the tty1 console session is logged in" \
  ssh_guest "loginctl list-sessions --no-legend | grep -q '$GUEST_USER.*tty1'"
check "provisioning completed" \
  ssh_guest "! test -f /var/lib/omarchy/provisioning/pending"

# --- verbose boot (no Plymouth splash) ---

ssh_guest "cat /proc/cmdline" >"$RUN_DIR/cmdline.txt" || true

check "the cmdline disables plymouth" \
  ssh_guest "grep -qw plymouth.enable=0 /proc/cmdline"
check "the cmdline ends on a visible loglevel" \
  ssh_guest "[[ \$(grep -o 'loglevel=[0-9]*' /proc/cmdline | tail -1) == loglevel=4 ]]"
check "plymouth is not running" \
  ssh_guest "! pidof plymouthd"
# Unpack each Omarchy UKI's initramfs; none may carry the plymouth hook. The
# btrfs-overlayfs hook must be listed, so an unreadable image cannot pass.
check "the boot image has no plymouth hook" \
  ssh_sudo 'set -e; shopt -s nullglob; ukis=(/boot/EFI/Linux/omarchy_*.efi); (( ${#ukis[@]} )); for uki in "${ukis[@]}"; do objcopy -O binary --only-section=.initrd "$uki" /tmp/initrd.img; files=$(lsinitcpio /tmp/initrd.img); grep -q "hooks/btrfs-overlayfs" <<<"$files"; if grep -q "hooks/plymouth" <<<"$files"; then exit 1; fi; done; rm -f /tmp/initrd.img'

# --- remote access ---

check "sshd is active" \
  ssh_guest "systemctl is-active sshd.service"
check "the firewall is enabled" \
  ssh_guest "systemctl is-enabled ufw.service"
check "the firewall allows ssh" \
  ssh_sudo "grep -q -- '--dport 22 ' /etc/ufw/user.rules"
check "the firewall does not open LocalSend" \
  ssh_sudo "! grep -q 53317 /etc/ufw/user.rules"

# --- packages ---

check "the stock kernel is installed" \
  ssh_guest "pacman -Q linux"
check "linux-omarchy was coerced to stock linux" \
  ssh_guest "! pacman -Q linux-omarchy"
check "the CLI/server core is installed" \
  ssh_guest "pacman -Q git docker openssh mise-bin starship nvim tmux"
check "no desktop stack is installed" \
  ssh_guest "! pacman -Q hyprland && ! pacman -Q sddm && ! pacman -Q chromium"
check "docker is enabled" \
  ssh_guest "systemctl is-enabled docker.socket"

# --- network install ---

# A headless ISO carries no offline mirror; pacstrap synced the channel's
# online repos plus omarchy-local, and those databases stay in the target.
stat -c %s "$ISO" >"$RUN_DIR/iso-size-bytes.txt"
check "the ISO is under the 1.9 GB release gate" \
  test "$(cat "$RUN_DIR/iso-size-bytes.txt")" -le 1900000000
check "packages came from the online repos" \
  ssh_guest "test -f /var/lib/pacman/sync/core.db && test -f /var/lib/pacman/sync/omarchy.db"
check "nothing came from an offline mirror" \
  ssh_guest "! test -e /var/lib/pacman/sync/offline.db"

# The cidata drive's static connection (base-test.sh) was loaded by the live
# installer and carried to the installed server, which brought it up.
check "the installer's static connection reached the server" \
  ssh_sudo "test \$(stat -c %a /etc/NetworkManager/system-connections/omarchy-test-static.nmconnection) = 600"
check "the static connection is active" \
  ssh_guest "nmcli -t -f NAME connection show --active | grep -qx omarchy-test-static"

# --- delayed packages (mise wrappers) ---

check "mise runs" \
  ssh_login "mise --version"
check "the gh wrapper is installed" \
  ssh_login "test -x ~/.local/bin/gh"
check "the gh wrapper resolves on first use" \
  ssh_login "timeout 300 gh --version"

ssh_guest "systemctl --failed --no-legend" >"$RUN_DIR/failed-units.txt" || true
check "no systemd units failed" \
  test ! -s "$RUN_DIR/failed-units.txt"

capture_console "success-final"
finish
