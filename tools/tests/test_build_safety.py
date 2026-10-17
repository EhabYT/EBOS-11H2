import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_safety_builder", TOOLS / "build-playbook.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BundleChecks(unittest.TestCase):
    def check_assets(self, cli_name=None, mods=True, dll=True, brave_name="BraveSetup.exe"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            exe = root / "Executables"
            exe.mkdir()
            for name in ("vc_redist.x64.exe", brave_name, "windhawk_setup.exe"):
                (exe / name).write_bytes(b"test fixture, not a real executable")
            cache = exe / "windhawk-cache"
            cache.mkdir()
            if mods:
                for mod in ("windows-11-taskbar-styler", "windows-11-file-explorer-styler"):
                    folder = cache / mod
                    folder.mkdir()
                    if dll:
                        (folder / "fixture.dll").write_bytes(b"test fixture, not a real DLL")
            if cli_name:
                (exe / cli_name).write_bytes(b"test fixture, not a real executable")
            report = builder.Report()
            with patch.object(builder, "ROOT", root):
                builder.check_assets(report, {})
            return report

    def test_gui_is_not_a_cli_installer(self):
        report = self.check_assets()
        self.assertEqual(1, len(report.warnings))
        self.assertIn("windhawk-cli", report.warnings[0])

    def test_cli_installer_pattern_matches_runtime(self):
        for name in ("windhawk-cli-1.1.0-installer.exe", "windhawk-cli-installer.exe"):
            with self.subTest(name=name):
                self.assertEqual([], self.check_assets(name).warnings)

    def test_empty_cache_is_not_an_offline_bundle(self):
        report = self.check_assets("windhawk-cli-installer.exe", mods=False)
        self.assertEqual(2, len(report.warnings))
        self.assertTrue(all("required mod" in w for w in report.warnings))

    def test_cache_requires_precompiled_dlls(self):
        report = self.check_assets("windhawk-cli-installer.exe", dll=False)
        self.assertEqual(2, len(report.warnings))
        self.assertTrue(all("precompiled DLL" in w for w in report.warnings))

    def test_brave_alias_matches_runtime(self):
        report = self.check_assets("windhawk-cli-installer.exe", brave_name="brave-setup.exe")
        self.assertEqual([], report.warnings)

    def test_options_still_default_unticked(self):
        conf = builder.ET.parse(TOOLS.parent / "playbook.conf").getroot()
        for name in ("windhawk-styler", "offline-mode"):
            options = [n for n in conf.iter("CheckboxOption") if n.findtext("Name") == name]
            self.assertEqual(1, len(options))
            self.assertEqual("false", options[0].get("IsChecked"))


class ArchiveEncryptionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Configuration").mkdir()
        self.files = [self.root / "playbook.conf", self.root / "Configuration" / "main.yml"]
        for path in self.files:
            path.write_text("non-empty payload for encryption regression tests\n")
        self.archive = self.root / "fixture.apbx"

    def test_custom_compression_chain_encrypts_payload_and_header(self):
        import py7zr
        with patch.object(builder, "ROOT", self.root):
            builder.build(self.files, self.archive)
        names, problems, digest = builder.verify_archive(self.archive)
        self.assertEqual([], problems)
        self.assertEqual(["playbook.conf", "Configuration/main.yml"], names)
        self.assertEqual(64, len(digest))
        with py7zr.SevenZipFile(self.archive, password=builder.PASSWORD) as archive:
            self.assertIn("7zAES", archive.archiveinfo().method_names)
            extracted = self.root / "extracted"
            archive.extractall(extracted)
        for path in self.files:
            self.assertEqual(path.read_bytes(), (extracted / path.relative_to(self.root)).read_bytes())
        with self.assertRaises(py7zr.PasswordRequired):
            py7zr.SevenZipFile(self.archive).close()

    def test_header_only_encryption_is_rejected(self):
        import py7zr
        with py7zr.SevenZipFile(self.archive, "w", password=builder.PASSWORD,
                               header_encryption=True, filters=[{"id": py7zr.FILTER_LZMA2}]) as archive:
            for path in self.files:
                archive.write(path, arcname=path.relative_to(self.root).as_posix())
        _, problems, _ = builder.verify_archive(self.archive)
        self.assertIn("archive payload is not fully AES-256 encrypted", problems)
        self.assertNotIn("archive headers are not encrypted", problems)

    def test_payload_only_encryption_is_rejected(self):
        import py7zr
        with py7zr.SevenZipFile(self.archive, "w", password=builder.PASSWORD,
                               header_encryption=False) as archive:
            for path in self.files:
                archive.write(path, arcname=path.relative_to(self.root).as_posix())
        _, problems, _ = builder.verify_archive(self.archive)
        self.assertIn("archive headers are not encrypted", problems)
        self.assertNotIn("archive payload is not fully AES-256 encrypted", problems)


class BuildReportTests(unittest.TestCase):
    def test_sidecars_are_regenerated_with_measured_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "release" / "EBOS-v11.2.apbx"
            artifact.parent.mkdir()
            artifact.write_bytes(b"archive metadata test fixture")
            notes = root / "docs" / "releases" / "11.2.md"
            notes.parent.mkdir(parents=True)
            notes.write_text("# EBOS 11.2\n")
            report = builder.Report()
            report.note("static check fixture")
            report.warn("missing input fixture")
            digest = "d" * 64
            with patch.object(builder, "ROOT", root):
                builder.write_build_report(artifact, "11.2", ["playbook.conf"], digest, report)
            text = (artifact.parent / "BUILD-REPORT.md").read_text()
            self.assertIn("Size: %d bytes" % artifact.stat().st_size, text)
            self.assertIn("static check fixture", text)
            self.assertIn("missing input fixture", text)
            self.assertIn("does not execute the playbook", text)
            self.assertEqual(digest + "  EBOS-v11.2.apbx\n", (artifact.parent / "SHA256SUMS.txt").read_text())
            self.assertIn(digest, (artifact.parent / "RELEASE-NOTES-11.2.md").read_text())


class VerifierPowerShellTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("pwsh") or shutil.which("powershell"),
                         "PowerShell is not installed; mocked verifier execution requires pwsh/Windows PowerShell")
    def test_real_verifier_blocks_with_mocked_reads(self):
        shell = shutil.which("pwsh") or shutil.which("powershell")
        result = subprocess.run(
            [shell, "-NoProfile", "-NonInteractive", "-File", str(TOOLS / "tests" / "test_verify_tasks.ps1")],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("Verifier unit tests passed:", result.stdout)


if __name__ == "__main__":
    unittest.main()
