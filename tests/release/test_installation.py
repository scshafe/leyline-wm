#!/usr/bin/env python3
"""Check the native v1 installer without registering or starting a service.

Inputs: LEYLINE_CORE_BIN points to a compiled native executable; LEYLINE_HOME
may override the checkout/resource directory. Tests use temporary roots only.
Installation mutations always use --no-start; uninstall/service operations use
--plan. The sole real launchctl action is read-only inspection of the v1 label.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RESOURCE_SOURCE = Path(os.environ.get("LEYLINE_HOME", REPOSITORY))
LABEL = "org.leyline.leylined"
PRIVATE_SETTINGS = {
    "schema": "leyline/resident-settings/v1",
    "spaces_enabled": {"fixture-desktop": False},
    "desired_running": False,
    "global_gutter_width": 17,
}
PRIVATE_BORDERS = {"width": 17, "colors.focus": "0xff00ff00"}


class NativeInstallationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        raw = os.environ.get("LEYLINE_CORE_BIN")
        if not raw:
            raise RuntimeError("LEYLINE_CORE_BIN must name a compiled native executable")
        cls.binary = Path(raw).resolve(strict=True)
        if not cls.binary.is_file() or not os.access(cls.binary, os.X_OK):
            raise RuntimeError("LEYLINE_CORE_BIN must be executable")
        # Never change a developer's live job to satisfy a test precondition.
        result = subprocess.run(
            ["/bin/launchctl", "print", f"gui/{os.geteuid()}/{LABEL}"],
            text=True, capture_output=True, check=False,
        )
        if result.returncode != 113:
            raise RuntimeError(
                "Temporary no-start integration requires the v1 label to be absent; "
                "the registered job was left untouched. Fake-launchctl self-tests "
                "remain available via 'leylined self-test installation'."
            )

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="leyline-v1-install-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "resident"
        self.agents = self.base / "LaunchAgents"
        self.resources = self.base / "resources"
        for relative in [
            "VERSION", "keymap/decode-us.json", "keymap/global.json",
            "keymap/modes.json",
        ]:
            target = self.resources / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(RESOURCE_SOURCE / relative, target)
            target.chmod(0o600)

    def command(self, operation: str, *arguments: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        result = subprocess.run(
            [str(self.binary), operation, "--root", str(self.root),
             "--launch-agents", str(self.agents), "--resource-home", str(self.resources),
             "--executable", str(self.binary), *arguments],
            text=True, capture_output=True, check=False,
        )
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            self.fail(f"Installer did not return one JSON envelope: {result.stdout!r} {result.stderr!r}: {error}")
        self.assertEqual(set(response), {"data", "error", "meta"})
        self.assertEqual(response["meta"]["transport"], "native_installation")
        self.assertTrue(response["meta"]["request_id"])
        return result, response

    def install(self) -> dict:
        result, response = self.command("install", "--no-start")
        self.assertEqual(result.returncode, 0, response)
        self.assertIsNone(response["error"])
        self.assertFalse(response["data"]["registered"])
        return response

    def assert_refused(self, operation: str, *arguments: str, code: str) -> dict:
        result, response = self.command(operation, *arguments)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(response["error"]["code"], code, response)
        self.assertIsNone(response["data"])
        return response

    def test_install_plan_has_no_filesystem_mutations(self) -> None:
        before = {str(path.relative_to(self.base)) for path in self.base.rglob("*")}
        result, response = self.command("install", "--plan", "--no-start")
        self.assertEqual(result.returncode, 0, response)
        self.assertFalse(response["data"]["registration_checked"])
        self.assertFalse(response["data"]["applied"])
        self.assertEqual(before, {str(path.relative_to(self.base)) for path in self.base.rglob("*")})

    def test_no_start_install_creates_one_private_direct_job(self) -> None:
        self.install()
        path = self.agents / f"{LABEL}.plist"
        plist = plistlib.loads(path.read_bytes())
        self.assertEqual(plist["Label"], LABEL)
        self.assertEqual(plist["ProgramArguments"], [str(self.binary), "core"])
        self.assertEqual(plist["ThrottleInterval"], 1)
        self.assertTrue(plist["KeepAlive"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["Umask"], 0o077)
        self.assertEqual(sorted(self.agents.iterdir()), [path])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        for directory in [self.root, self.root / "config", self.root / "runtime",
                          self.root / "runtime/sockets", self.root / "state",
                          self.root / "state/leylined", self.agents]:
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700, directory)

    def test_no_start_install_seeds_documented_nested_border_defaults(self) -> None:
        self.install()
        expected = {"border_radius": 12, "colors": {
            "focus": "0xff39ff14", "resizing": "0xffff8c00", "moved": "0xff2962ff",
            "move_to": "0xffff5fa2", "drop_edge": "0xffffd400"}}
        self.assertEqual(json.loads((self.root / "config/borders.json").read_text()), expected)

    def test_repeated_no_start_install_preserves_bytes_and_timestamps(self) -> None:
        self.install()
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in [*self.root.rglob("*"), *self.agents.rglob("*")] if path.is_file()}
        response = self.install()
        self.assertFalse(response["data"]["applied"])
        self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in before})

    def test_reinstall_preserves_user_preferences_and_journal(self) -> None:
        self.install()
        settings = self.root / "config/leylined-settings.json"
        borders = self.root / "config/borders.json"
        journal = self.root / "state/leylined/journal.jsonl"
        settings.write_text(json.dumps(PRIVATE_SETTINGS) + "\n")
        borders.write_text(json.dumps(PRIVATE_BORDERS) + "\n")
        journal.write_bytes(b"private journal evidence\n")
        journal.chmod(0o600)
        before = {path: path.read_bytes() for path in [settings, borders, journal]}
        self.install()
        self.assertEqual(before, {path: path.read_bytes() for path in before})

    def test_uninstall_plan_preserves_installed_files(self) -> None:
        self.install()
        before = {path: path.read_bytes() for path in [*self.root.rglob("*"), *self.agents.rglob("*")] if path.is_file()}
        result, response = self.command("uninstall", "--plan")
        self.assertEqual(result.returncode, 0, response)
        self.assertFalse(response["data"]["registration_checked"])
        self.assertEqual(before, {path: path.read_bytes() for path in before})

    def test_all_service_plans_have_no_mutations(self) -> None:
        for operation in ["service-status", "service-start", "service-stop", "service-restart"]:
            with self.subTest(operation=operation):
                result, response = self.command(operation, "--plan")
                self.assertEqual(result.returncode, 0, response)
                self.assertFalse(response["data"]["applied"])
                self.assertFalse(self.root.exists())
                self.assertFalse(self.agents.exists())

    def test_missing_resource_is_refused_before_installation_writes(self) -> None:
        (self.resources / "keymap/modes.json").unlink()
        self.assert_refused("install", "--no-start", code="INSTALL.RESOURCES_UNAVAILABLE")
        self.assertFalse(self.root.exists())
        self.assertFalse(self.agents.exists())

    def test_resource_version_mismatch_is_refused(self) -> None:
        (self.resources / "VERSION").write_text("999.0.0\n")
        self.assert_refused("install", "--no-start", code="INSTALL.VERSION_MISMATCH")
        self.assertFalse(self.root.exists())

    def test_root_symlink_is_refused_without_touching_target(self) -> None:
        target = self.base / "outside"
        target.mkdir(mode=0o700)
        self.root.symlink_to(target, target_is_directory=True)
        self.assert_refused("install", "--no-start", code="INSTALL.PATH_UNSAFE")
        self.assertEqual(list(target.iterdir()), [])

    def test_plist_symlink_is_refused_without_replacing_target(self) -> None:
        self.agents.mkdir(mode=0o700)
        target = self.base / "outside.plist"
        target.write_bytes(b"private unrelated contents")
        target.chmod(0o600)
        (self.agents / f"{LABEL}.plist").symlink_to(target)
        self.assert_refused("install", "--no-start", code="INSTALL.FILE_UNSAFE")
        self.assertEqual(target.read_bytes(), b"private unrelated contents")
        self.assertFalse(self.root.exists())

    def test_group_writable_directory_is_refused(self) -> None:
        self.root.mkdir(mode=0o700)
        self.root.chmod(0o770)
        self.assert_refused("install", "--no-start", code="INSTALL.PATH_UNSAFE")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_nonprivate_existing_plist_is_refused(self) -> None:
        self.install()
        path = self.agents / f"{LABEL}.plist"
        path.chmod(0o644)
        before = path.read_bytes()
        self.assert_refused("install", "--no-start", code="INSTALL.PATH_UNSAFE")
        self.assertEqual(path.read_bytes(), before)

    def test_explicit_update_is_required_for_different_installed_plist(self) -> None:
        self.install()
        path = self.agents / f"{LABEL}.plist"
        previous = plistlib.loads(path.read_bytes())
        previous["EnvironmentVariables"]["LEYLINE_HOME"] = str(self.resources / "old-location")
        path.write_bytes(plistlib.dumps(previous))
        before = path.read_bytes()
        self.assert_refused("install", "--no-start", code="INSTALL.UPDATE_REQUIRED")
        self.assertEqual(path.read_bytes(), before)
        result, response = self.command("install", "--no-start", "--update")
        self.assertEqual(result.returncode, 0, response)
        self.assertEqual(plistlib.loads(path.read_bytes())["EnvironmentVariables"]["LEYLINE_HOME"], str(self.resources))

    def test_launchd_execution_overrides_are_refused_before_replacement(self) -> None:
        self.install()
        path = self.agents / f"{LABEL}.plist"
        canonical = plistlib.loads(path.read_bytes())
        for key in ["Program", "BundleProgram", "MachServices"]:
            with self.subTest(key=key):
                overridden = dict(canonical)
                overridden[key] = "/bin/false"
                path.write_bytes(plistlib.dumps(overridden))
                before = path.read_bytes()
                self.assert_refused("install", "--no-start", "--update", code="INSTALL.PLIST_INVALID")
                self.assertEqual(path.read_bytes(), before)

    def test_unrecognized_job_environment_is_refused(self) -> None:
        self.install()
        path = self.agents / f"{LABEL}.plist"
        previous = plistlib.loads(path.read_bytes())
        previous["EnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] = "/private/untrusted.dylib"
        path.write_bytes(plistlib.dumps(previous))
        before = path.read_bytes()
        self.assert_refused("install", "--no-start", "--update", code="INSTALL.PLIST_INVALID")
        self.assertEqual(path.read_bytes(), before)

    def test_existing_owned_launchagents_directory_becomes_private(self) -> None:
        self.agents.mkdir(mode=0o755)
        self.install()
        self.assertEqual(stat.S_IMODE(self.agents.stat().st_mode), 0o700)

    def test_unknown_options_and_conflicting_start_flags_are_typed_errors(self) -> None:
        self.assert_refused("install", "--no-start", "--start", code="INSTALL.ARGUMENT_INVALID")
        self.assert_refused("install", "--unexpected", code="INSTALL.ARGUMENT_INVALID")
        self.assert_refused("service-stop", "--update", code="INSTALL.ARGUMENT_INVALID")
        self.assertFalse(self.root.exists())

    def test_relative_and_root_directory_paths_are_refused(self) -> None:
        for flag, path in [("--root", "relative"), ("--root", "/"), ("--launch-agents", "relative")]:
            with self.subTest(flag=flag, path=path):
                arguments = [str(self.binary), "install", flag, path, "--plan"]
                result = subprocess.run(arguments, text=True, capture_output=True, check=False)
                response = json.loads(result.stdout)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(response["error"]["code"], "INSTALL.PATH_INVALID")


if __name__ == "__main__":
    unittest.main(verbosity=2)
