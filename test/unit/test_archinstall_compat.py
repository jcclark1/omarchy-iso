"""Unit tests for the archinstall adapter's cross-release compatibility.

archinstall is not installed where these tests run, so its modules are stubbed
and the real adapter file is loaded under its own name (other tests replace
orchestrator.archinstall_adapter in sys.modules with an empty stub).
"""

import importlib.util
import sys
import types
import unittest
from pathlib import Path

ORCHESTRATOR = Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"
sys.path.insert(0, str(ORCHESTRATOR))

ARCHINSTALL_NAMES = {
    "archinstall.lib.args": ["ArchConfig", "ArchConfigHandler"],
    "archinstall.lib.authentication.authentication_handler": ["AuthenticationHandler"],
    "archinstall.lib.disk.filesystem": ["FilesystemHandler"],
    "archinstall.lib.disk.utils": ["get_parent_device_path", "get_unique_path_for_device", "udev_sync"],
    "archinstall.lib.hardware": ["SysInfo"],
    "archinstall.lib.installer": ["Installer"],
    "archinstall.lib.mirror.mirror_handler": ["MirrorListHandler"],
    "archinstall.lib.models": ["Bootloader"],
    "archinstall.lib.models.device": ["DiskLayoutType", "EncryptionType"],
    "archinstall.lib.models.users": ["User"],
}


def _load_adapter():
    for module_name, names in ARCHINSTALL_NAMES.items():
        parts = module_name.split(".")
        for i in range(1, len(parts) + 1):
            sys.modules.setdefault(".".join(parts[:i]), types.ModuleType(".".join(parts[:i])))
        for name in names:
            setattr(sys.modules[module_name], name, type(name, (), {}))

    spec = importlib.util.spec_from_file_location(
        "orchestrator.archinstall_adapter_under_test",
        ORCHESTRATOR / "orchestrator/archinstall_adapter.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = _load_adapter()


class Installer44:
    def __init__(self):
        self.calls = []

    def sanity_check(self, offline=False, skip_ntp=False, skip_wkd=False):
        self.calls.append({"offline": offline, "skip_ntp": skip_ntp, "skip_wkd": skip_wkd})


class Installer45:
    def __init__(self):
        self.calls = []

    def sanity_check(self, skip_ntp=False, skip_wkd=False):
        self.calls.append({"skip_ntp": skip_ntp, "skip_wkd": skip_wkd})


class SanityCheckTest(unittest.TestCase):
    def test_archinstall_44_gets_offline(self):
        installer = Installer44()
        adapter.sanity_check(installer)
        self.assertEqual(installer.calls, [{"offline": True, "skip_ntp": True, "skip_wkd": True}])

    def test_archinstall_45_omits_offline(self):
        # 4.5 dropped the flag; passing it raised TypeError and halted every install.
        installer = Installer45()
        adapter.sanity_check(installer)
        self.assertEqual(installer.calls, [{"skip_ntp": True, "skip_wkd": True}])


if __name__ == "__main__":
    unittest.main()
