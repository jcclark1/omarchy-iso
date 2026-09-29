#!/bin/bash
#
# Headless server profile: proves a --headless ISO installs a console-only
# Omarchy server. Boots the installed base and asserts it came up on the
# server profile: multi-user.target with tty1 autologin instead of a display
# manager, SSH enabled and let through the firewall, the stock kernel (the
# cidata config asks for linux-omarchy, which the server install coerces),
# the CLI/dev core installed with no desktop stack, and the mise wrappers
# ("delayed packages") resolving on first use.
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
