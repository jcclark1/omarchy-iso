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


if __name__ == "__main__":
    unittest.main()
