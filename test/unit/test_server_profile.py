"""Unit tests for the server/headless install profile.

Covers profile resolution, the profile-aware kernel default, writing the target
profile marker, and the runtime package-list selecting the server manifest.
"""

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope; stub it out.
sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import context, phases_impl  # noqa: E402


class ResolveProfileTest(unittest.TestCase):
    def test_config_value_wins(self):
        self.assertEqual(context._resolve_profile({"profile": "server"}), "server")

    def test_unknown_value_is_desktop(self):
        self.assertEqual(context._resolve_profile({"profile": "nope"}), "desktop")

    def test_empty_is_desktop_without_marker(self):
        self.assertEqual(context._resolve_profile({}, marker=Path("/nonexistent")), "desktop")

    def test_marker_file_selects_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "profile"
            marker.write_text("server\n")
            self.assertEqual(context._resolve_profile({}, marker=marker), "server")

    def test_config_overrides_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "profile"
            marker.write_text("server\n")
            # An explicit desktop config beats a server marker.
            self.assertEqual(context._resolve_profile({"profile": "desktop"}, marker=marker), "desktop")


class DefaultKernelTest(unittest.TestCase):
    def _pci(self, tmp, vendor, device):
        slot = Path(tmp) / "0000:00:00.0"
        slot.mkdir()
        (slot / "vendor").write_text(vendor + "\n")
        (slot / "device").write_text(device + "\n")
        return Path(tmp)

    def test_server_defaults_to_stock_linux(self):
        with tempfile.TemporaryDirectory() as tmp:
            pci = self._pci(tmp, "0x8086", "0xb080")
            self.assertEqual(context._default_kernel(pci, profile="server"), "linux")

    def test_desktop_defaults_to_omarchy_kernel(self):
        with tempfile.TemporaryDirectory() as tmp:
            pci = self._pci(tmp, "0x8086", "0xb080")
            self.assertEqual(context._default_kernel(pci, profile="desktop"), "linux-omarchy")

    def test_t2_wins_even_on_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            pci = self._pci(tmp, "0x106b", "0x1801")
            self.assertEqual(context._default_kernel(pci, profile="server"), "linux-t2")


class WriteProfileMarkerTest(unittest.TestCase):
    def test_writes_marker_into_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = mock.Mock(target=Path(tmp), profile="server")
            phases_impl._write_profile_marker(ctx)
            self.assertEqual((Path(tmp) / "etc/omarchy/profile").read_text(), "server\n")


class ServerKernelCoercionTest(unittest.TestCase):
    """A server install must land on the stock kernel that the server mirror
    carries, even when a config names the desktop linux-omarchy kernel."""

    def _from_env(self, config):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = root / "config.json"
            creds_path = root / "creds.json"
            config_path.write_text(json.dumps(config))
            creds_path.write_text(json.dumps({"users": [{"username": "test"}]}))
            with mock.patch.dict(os.environ, {
                "OMARCHY_INSTALL_CONFIG": str(config_path),
                "OMARCHY_INSTALL_CREDS": str(creds_path),
                "OMARCHY_INSTALL_STATE_DIR": str(root / "state"),
            }, clear=True):
                return context.InstallContext.from_env()

    def test_linux_omarchy_is_coerced_to_stock_on_server(self):
        ctx = self._from_env({"omarchy_install": {"profile": "server"}, "kernels": ["linux-omarchy"]})
        self.assertEqual(ctx.profile, "server")
        self.assertEqual(ctx.user_configuration["kernels"], ["linux"])

    def test_desktop_keeps_linux_omarchy(self):
        ctx = self._from_env({"kernels": ["linux-omarchy"]})
        self.assertEqual(ctx.user_configuration["kernels"], ["linux-omarchy"])

    def test_explicit_t2_kernel_survives_on_server(self):
        ctx = self._from_env({"omarchy_install": {"profile": "server"}, "kernels": ["linux-t2"]})
        self.assertEqual(ctx.user_configuration["kernels"], ["linux-t2"])


class ConfigureLoginTest(unittest.TestCase):
    """The server profile leaves login to headless.sh: configure_login is a no-op
    and must not enable sddm or delete the getty autologin."""

    def test_server_is_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            # A getty autologin drop-in as headless.sh would have left it.
            autologin = target / "etc/systemd/system/getty@tty1.service.d/autologin.conf"
            autologin.parent.mkdir(parents=True, exist_ok=True)
            autologin.write_text("[Service]\n")

            ctx = mock.Mock(target=target, profile="server", encrypt=False,
                            defer_provisioning=False, username="jeremy")
            with mock.patch.object(phases_impl.subprocess, "run") as run:
                phases_impl.configure_login(ctx)

            run.assert_not_called()  # no arch-chroot systemctl enable sddm
            self.assertTrue(autologin.exists(), "server autologin must survive")
            self.assertFalse((target / "etc/sddm.conf.d").exists(), "no sddm config on server")


class ApplicationSelectionsTest(unittest.TestCase):
    """archinstall's audio/Bluetooth selections are skipped on a server: its
    mirror lacks their packages (pipewire-alsa, wireplumber, ...), which failed
    pacstrap."""

    def _wants(self, profile, app_config):
        ctx = mock.Mock(profile=profile)
        config = mock.Mock(app_config=app_config)
        return phases_impl._wants_application_selections(ctx, config)

    def test_server_skips_audio(self):
        self.assertFalse(self._wants("server", {"audio_config": {"audio": "pipewire"}}))

    def test_desktop_installs_audio(self):
        self.assertTrue(self._wants("desktop", {"audio_config": {"audio": "pipewire"}}))

    def test_nothing_selected(self):
        self.assertFalse(self._wants("desktop", None))


class RuntimePackageListTest(unittest.TestCase):
    """The server profile reads omarchy-server.packages; desktop reads base."""

    def _run(self, profile, base_body, server_body):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "omarchy-base.packages"
            server = Path(tmp) / "omarchy-server.packages"
            base.write_text(base_body)
            server.write_text(server_body)

            real_path = phases_impl.Path
            redirect = {
                "/usr/share/omarchy-iso/omarchy-base.packages": base,
                "/usr/share/omarchy-iso/omarchy-server.packages": server,
            }

            def fake_path(p="", *a, **k):
                return redirect.get(str(p), real_path(p, *a, **k))

            ctx = mock.Mock(profile=profile)
            with mock.patch.object(phases_impl, "Path", side_effect=fake_path), \
                mock.patch.object(phases_impl, "_omarchy_runtime_package", return_value="omarchy"), \
                mock.patch.object(phases_impl, "_omarchy_settings_package", return_value="omarchy-settings"), \
                mock.patch.object(phases_impl, "_omarchy_nvim_package", return_value="omarchy-nvim"), \
                mock.patch.object(phases_impl, "_early_packages", return_value=[]):
                return phases_impl._runtime_package_list(ctx)

    def test_server_reads_server_manifest(self):
        pkgs = self._run("server", "hyprland\nsddm\n", "openssh\nmise-bin\n")
        self.assertIn("openssh", pkgs)
        self.assertIn("mise-bin", pkgs)
        self.assertNotIn("hyprland", pkgs)

    def test_desktop_reads_base_manifest(self):
        pkgs = self._run("desktop", "hyprland\nsddm\n", "openssh\nmise-bin\n")
        self.assertIn("hyprland", pkgs)
        self.assertNotIn("openssh", pkgs)



class NetworkInstallTest(unittest.TestCase):
    """A headless ISO installs from the channel's online repos."""

    CONFIGS = Path(__file__).resolve().parents[2] / "configs"

    def test_only_server_is_a_network_install(self):
        self.assertTrue(phases_impl._is_network_install(mock.Mock(profile="server")))
        self.assertFalse(phases_impl._is_network_install(mock.Mock(profile="desktop")))

    def test_core_db_url_uses_the_channel_snapshot_mirror(self):
        for channel, host in (("stable", "stable-mirror"), ("edge", "mirror")):
            conf = (self.CONFIGS / f"pacman-online-{channel}.conf").read_text()
            self.assertEqual(
                phases_impl._core_db_url(conf),
                f"https://{host}.omarchy.org/core/os/x86_64/core.db",
            )

    def test_core_db_url_skips_local_repos(self):
        conf = "[options]\n[omarchy-local]\nServer = file:///x/\n[core]\nServer = file:///y/\nServer = https://m/$repo/os/$arch\n"
        self.assertEqual(phases_impl._core_db_url(conf), "https://m/core/os/x86_64/core.db")

    def test_core_db_url_rejects_an_offline_conf(self):
        conf = (self.CONFIGS / "pacman-offline.conf").read_text()
        with self.assertRaises(RuntimeError):
            phases_impl._core_db_url(conf)

    def test_unreachable_mirror_fails_with_the_network_message(self):
        failed = mock.Mock(returncode=6, stderr="Could not resolve host")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=failed), \
                mock.patch.object(phases_impl.time, "sleep"):
            with self.assertRaises(RuntimeError) as caught:
                phases_impl._require_network("https://m/core.db", wait_seconds=0)
        self.assertIn("wired network with DHCP", str(caught.exception))
        self.assertIn("Could not resolve host", str(caught.exception))

    def test_reachable_mirror_passes(self):
        ok = mock.Mock(returncode=0, stderr="")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=ok) as run:
            phases_impl._require_network("https://m/core.db")
        self.assertEqual(run.call_count, 1)

    def test_keyring_timeout_is_a_clear_error(self):
        timeout = phases_impl.subprocess.TimeoutExpired("systemctl", 1)
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=timeout):
            with self.assertRaisesRegex(RuntimeError, "pacman-init"):
                phases_impl._wait_for_pacman_keyring(wait_seconds=1)

    def _target_bind_sources(self, profile):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = mock.Mock(target=Path(tmp), profile=profile, state={})
            (ctx.target / "etc").mkdir()
            with mock.patch.object(phases_impl.shutil, "copy"), \
                    mock.patch.object(phases_impl.subprocess, "run") as run:
                phases_impl._prepare_target_setup(ctx)
            return [c.args[0][2] for c in run.call_args_list]

    def test_server_target_setup_binds_the_local_repo(self):
        self.assertEqual(
            self._target_bind_sources("server"),
            ["/var/cache/omarchy/mirror/local", "/opt/packages"],
        )

    def test_desktop_target_setup_binds_the_offline_mirror(self):
        self.assertEqual(
            self._target_bind_sources("desktop"),
            ["/var/cache/omarchy/mirror/offline", "/opt/packages"],
        )


if __name__ == "__main__":
    unittest.main()


class CopyNetworkConnectionsTest(unittest.TestCase):
    def test_connections_reach_the_target_root_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp) / "live"
            live.mkdir()
            (live / "lan.nmconnection").write_text("[connection]\nid=lan\n")
            (live / "notes.txt").write_text("not a connection")
            target = Path(tmp) / "target"
            phases_impl._copy_network_connections(mock.Mock(target=target), source=live)
            copied = target / "etc/NetworkManager/system-connections"
            self.assertEqual([p.name for p in copied.iterdir()], ["lan.nmconnection"])
            self.assertEqual((copied / "lan.nmconnection").stat().st_mode & 0o777, 0o600)
            self.assertEqual(copied.stat().st_mode & 0o777, 0o700)

    def test_cloud_init_connections_stay_behind(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp) / "live"
            live.mkdir()
            (live / "lan.nmconnection").write_text("[connection]\nid=lan\n")
            (live / "cloud-init-enp0s3.nmconnection").write_text(
                "[connection]\nid=cloud-init enp0s3\nautoconnect-priority=120\n\n"
                "[user]\norg.freedesktop.NetworkManager.origin=cloud-init\n"
            )
            target = Path(tmp) / "target"
            phases_impl._copy_network_connections(mock.Mock(target=target), source=live)
            copied = target / "etc/NetworkManager/system-connections"
            self.assertEqual([p.name for p in copied.iterdir()], ["lan.nmconnection"])

    def test_dhcp_install_copies_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target"
            phases_impl._copy_network_connections(mock.Mock(target=target), source=Path(tmp) / "missing")
            self.assertFalse((target / "etc").exists())

