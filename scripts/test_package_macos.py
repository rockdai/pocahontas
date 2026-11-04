import importlib.util
from pathlib import Path
import subprocess
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

    def test_stapling_failure_stops_distribution(self):
        with patch.object(package, "run", side_effect=[None, '{"status":"Accepted"}', subprocess.CalledProcessError(1, "stapler")]):
            with self.assertRaises(subprocess.CalledProcessError):
                package.notarize(Path("App.app"), Path("work"))

    def test_notices_include_dependencies_without_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage, derived = root / "output", root / "derived"
            stage.mkdir()
            for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Licenses/example.txt",
                         "assets/logo/fonts/OFL.txt", "Packages/PocahontasKit/Package.resolved",
                         "Frameworks/build-info.json", "vendor/ghostty/LICENSE",
                         ".cache/zig/p/dependency/LICENSE", "derived/SourcePackages/checkouts/dependency/LICENSE"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("fixture")
            (root / ".env").write_text("private fixture")
            (root / "vendor/ghostty/private.key").write_text("private fixture")
            with patch.object(package, "ROOT", root):
                package.copy_notices(stage, derived)
            self.assertTrue((stage / "DependencyNotices/ghostty/LICENSE").is_file())
            self.assertTrue((stage / "DependencyNotices/zig-packages/dependency/LICENSE").is_file())
            self.assertTrue((stage / "DependencyNotices/swift-packages/dependency/LICENSE").is_file())
            self.assertFalse(list(stage.rglob(".env")))
            self.assertFalse(list(stage.rglob("private.key")))


if __name__ == "__main__":
    unittest.main()
