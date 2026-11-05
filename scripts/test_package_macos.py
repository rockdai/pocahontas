import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("package_macos", Path(__file__).with_name("package-macos.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class SigningTests(unittest.TestCase):
    def test_only_developer_id_for_selected_team_is_used(self):
        identities = ('1) ' + 'A' * 40 + ' "Apple Development: Example (PERSONID)"\n'
                      '2) ' + 'B' * 40 + ' "Developer ID Application: Example (OTHER12345)"\n'
                      '3) ' + 'C' * 40 + ' "Developer ID Application: Example (TEAM123456)"')
        with patch.object(package, "run", side_effect=[identities, "{}"]):
            self.assertEqual(package.signing_identity("TEAM123456"), "C" * 40)

    def test_invalid_team_stops_before_accessing_credentials(self):
        for team in ("", "TEAM", "TEAM123456;echo"):
            with self.subTest(team=team), patch.object(package, "run") as run:
                with self.assertRaises(ValueError):
                    package.signing_identity(team)
                run.assert_not_called()

    def test_development_certificate_cannot_replace_developer_id(self):
        with patch.object(package, "run", return_value='A' * 40 + ' "Apple Development: Example (TEAM123456)"'):
            with self.assertRaises(ValueError):
                package.signing_identity("TEAM123456")

    def test_missing_notary_credentials_stop_the_build(self):
        identity = 'A' * 40 + ' "Developer ID Application: Example (TEAM123456)"'
        with patch.object(package, "run", side_effect=[identity, subprocess.CalledProcessError(1, "notarytool")]):
            with self.assertRaises(subprocess.CalledProcessError):
                package.signing_identity("TEAM123456")

    def test_accepted_submission_must_pass_staple_and_gatekeeper(self):
        with patch.object(package, "run", side_effect=[None, '{"status":"Accepted"}', None, None, None, None]) as run:
            package.notarize(Path("App.app"), Path("work"))
            self.assertEqual(run.call_args.args[:2], ("spctl", "--assess"))

    def test_rejected_or_unfinished_submission_is_not_stapled(self):
        for status in ("Invalid", "In Progress", "Rejected", None):
            with self.subTest(status=status):
                result = package.json.dumps({"status": status, "id": "test-submission"})
                with patch.object(package, "run", side_effect=[None, result]) as run:
                    with self.assertRaises(ValueError):
                        package.notarize(Path("App.app"), Path("work"))
                    self.assertEqual(run.call_count, 2)

    def test_rejected_submission_explains_how_to_fetch_the_log(self):
        result = '{"status":"Invalid","id":"01234567-89ab-cdef-0123-456789abcdef"}'
        with patch.object(package, "run", side_effect=[None, result]):
            with self.assertRaises(ValueError) as error:
                package.notarize(Path("App.app"), Path("work"))
        self.assertIn("xcrun notarytool log 01234567-89ab-cdef-0123-456789abcdef "
                      "--keychain-profile pocahontas-notary", str(error.exception))

    def test_pending_submission_suggests_status_check_instead_of_unavailable_log(self):
        with patch.object(package, "run", side_effect=[None, '{"status":"In Progress","id":"pending"}']):
            with self.assertRaises(ValueError) as error:
                package.notarize(Path("App.app"), Path("work"))
        self.assertIn("xcrun notarytool info pending", str(error.exception))
        self.assertNotIn("notarytool log", str(error.exception))

    def test_missing_submission_id_does_not_suggest_an_unusable_command(self):
        with patch.object(package, "run", side_effect=[None, '{"status":"Invalid"}']):
            with self.assertRaises(ValueError) as error:
                package.notarize(Path("App.app"), Path("work"))
        self.assertIn("Invalid", str(error.exception))
        self.assertNotIn("Inspect with:", str(error.exception))

    def test_stapling_failure_stops_distribution(self):
        with patch.object(package, "run", side_effect=[None, '{"status":"Accepted"}', subprocess.CalledProcessError(1, "stapler")]):
            with self.assertRaises(subprocess.CalledProcessError):
                package.notarize(Path("App.app"), Path("work"))

class BundleTests(unittest.TestCase):
    def test_bundle_uses_effective_build_versions(self):
        for version, build in (("0.1.0", "1"), ("2.3.4", "42")):
            with self.subTest(version=version, build=build):
                package.validate_bundle_info(
                    {"CFBundleIdentifier": "com.rockdai.pocahontas.mac",
                     "CFBundleShortVersionString": version, "CFBundleVersion": build},
                    {"MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build})

    def test_wrong_or_unexpanded_bundle_metadata_is_rejected(self):
        info = {"CFBundleIdentifier": "com.rockdai.pocahontas.mac",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}
        settings = {"MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1"}
        for key, wrong in (("CFBundleIdentifier", "another.app"),
                           ("CFBundleShortVersionString", "1.0"),
                           ("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
                           ("CFBundleVersion", "2"), ("CFBundleVersion", None)):
            with self.subTest(key=key, wrong=wrong), self.assertRaisesRegex(ValueError, key):
                package.validate_bundle_info({**info, key: wrong}, settings)

    def test_missing_build_versions_are_rejected_even_if_bundle_versions_are_missing(self):
        with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
            package.validate_bundle_info({"CFBundleIdentifier": "com.rockdai.pocahontas.mac"}, {})


class NoticeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="packaging fixtures ")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.stage, self.derived = self.root / "output", self.root / "derived"
        self.stage.mkdir()
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Licenses/example.txt",
                     "assets/logo/fonts/OFL.txt", "Packages/PocahontasKit/Package.resolved",
                     "Frameworks/build-info.json", "vendor/ghostty/LICENSE",
                     ".cache/zig/p/dependency/NOTICE.txt", "derived/SourcePackages/checkouts/dependency/COPYING",
                     "vendor/ghostty/.git/LICENSE", "vendor/ghostty/.build/LICENSE"):
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(name)
        (self.root / ".env").write_text("private fixture")
        (self.root / "vendor/ghostty/private.key").write_text("private fixture")

    def assert_notices(self):
        for destination, source in (("ghostty/LICENSE", "vendor/ghostty/LICENSE"),
                                    ("zig-packages/dependency/NOTICE.txt", ".cache/zig/p/dependency/NOTICE.txt"),
                                    ("swift-packages/dependency/COPYING", "derived/SourcePackages/checkouts/dependency/COPYING")):
            self.assertEqual((self.stage / "DependencyNotices" / destination).read_text(), source)
        self.assertFalse((self.stage / "DependencyNotices/ghostty/.git").exists())
        self.assertFalse((self.stage / "DependencyNotices/ghostty/.build").exists())
        self.assertFalse(list(self.stage.rglob(".env")))
        self.assertFalse(list(self.stage.rglob("private.key")))

    def test_notices_include_dependencies_without_private_files(self):
        with patch.object(package, "ROOT", self.root):
            package.copy_notices(self.stage, self.derived)
        self.assert_notices()

    def test_missing_dependency_sources_stop_packaging(self):
        for index, name in enumerate(("vendor/ghostty", ".cache/zig/p", "derived/SourcePackages/checkouts")):
            with self.subTest(name=name):
                tree = self.root / name
                missing = self.root / "missing"
                tree.rename(missing)
                try:
                    with patch.object(package, "ROOT", self.root), self.assertRaisesRegex(ValueError, "Missing dependency"):
                        package.copy_notices(self.root / f"output-{index}", self.derived)
                finally:
                    missing.rename(tree)

    def test_ad_hoc_packager_copies_notices_without_signing_setup(self):
        (self.root / "scripts").mkdir()
        shutil.copy2(package.__file__, self.root / "scripts/package-macos.py")
        info = self.derived / "Build/Products/Debug/Pocahontas.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"PocahontasServerURL": "https://example.invalid"}))
        script = Path(__file__).with_name("package-macos-test.sh").read_text()
        embedded = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        result = subprocess.run([sys.executable, "-", str(self.stage), "source-commit", str(self.root), str(self.derived)],
                                input=embedded, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_notices()
        instructions = (self.stage / "使用说明.txt").read_text()
        self.assertIn("source-commit", instructions)
        self.assertIn("https://example.invalid", instructions)


if __name__ == "__main__":
    unittest.main()
