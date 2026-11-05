import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PROFILE = "pocahontas-notary"


def run(*args, capture=False):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                          text=True, capture_output=capture).stdout


def signing_identity(team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Set APPLE_TEAM_ID to your paid Apple Developer team's 10-character ID.")
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    match = re.search(r'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \('
                      + re.escape(team) + r'\)"', identities)
    if not match:
        raise ValueError(f"Install a Developer ID Application identity for team {team} on this runner.")
    run("xcrun", "notarytool", "history", "--keychain-profile", PROFILE,
        "--output-format", "json", capture=True)
    return match.group(1)


def notarize(app, directory):
    submission = directory / "notarization.zip"
    run("ditto", "-c", "-k", "--keepParent", app, submission)
    result = json.loads(run("xcrun", "notarytool", "submit", submission,
                            "--keychain-profile", PROFILE, "--wait", "--timeout", "30m",
                            "--output-format", "json", capture=True))
    if result.get("status") != "Accepted":
        message = f"Notarization was not accepted: {result.get('status')}; submission {result.get('id')}"
        if result.get("id"):
            action = "log" if result.get("status") == "Invalid" else "info"
            command = shlex.join(["xcrun", "notarytool", action, result["id"], "--keychain-profile", PROFILE])
            message += f"\nInspect with: {command}"
        raise ValueError(message)
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    run("spctl", "--assess", "--type", "execute", app)


def copy_notices(stage, derived):
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Licenses", "assets/logo/fonts/OFL.txt",
                 "Packages/PocahontasKit/Package.resolved", "Frameworks/build-info.json"):
        source, destination = ROOT / name, stage / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)
    notice = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([._ -].*)?$", re.I)
    for label, tree in (("ghostty", ROOT / "vendor/ghostty"),
                        ("zig-packages", ROOT / ".cache/zig/p"),
                        ("swift-packages", derived / "SourcePackages/checkouts")):
        if not tree.is_dir():
            raise ValueError(f"Missing dependency sources for notices: {tree}")
        for folder, directories, files in os.walk(tree):
            directories[:] = [d for d in directories if d not in {".git", ".build", ".zig-cache", "zig-out"}]
            for name in files:
                if notice.match(name):
                    source = Path(folder) / name
                    destination = stage / "DependencyNotices" / label / source.relative_to(tree)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)


def validate_bundle_info(info, settings):
    expected = {"CFBundleIdentifier": "com.rockdai.pocahontas.mac",
                "CFBundleShortVersionString": settings.get("MARKETING_VERSION"),
                "CFBundleVersion": settings.get("CURRENT_PROJECT_VERSION")}
    for key, value in expected.items():
        if not value or info.get(key) != value:
            raise ValueError(f"Unexpected {key}: {info.get(key)!r}; expected {value!r}.")


def write_package(app, output, source):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".packaging-", dir=output) as staging_output:
        staging = Path(staging_output)
        pending = staging / f"Pocahontas-AppleSilicon-{source[:12]}.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, pending)
        verified = staging / "verify"
        run("ditto", "-x", "-k", pending, verified)
        verified_app = verified / app.name
        run("codesign", "--verify", "--deep", "--strict", verified_app)
        run("xcrun", "stapler", "validate", verified_app)
        checksum = hashlib.sha256(pending.read_bytes()).hexdigest()
        final = output / pending.name
        pending.replace(final)
        final.with_suffix(".zip.sha256").write_text(f"{checksum}  {final.name}\n")
    return final


def package():
    team = os.environ.get("APPLE_TEAM_ID", "")
    identity = signing_identity(team)
    if run("git", "status", "--porcelain", capture=True).strip():
        raise ValueError("Commit source changes before packaging.")
    source = run("git", "rev-parse", "HEAD", capture=True).strip()
    run(ROOT / "scripts/build-ghostty.sh")
    framework = ROOT / "Frameworks/GhosttyKit.xcframework"
    libraries = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
    for library in libraries:
        if library["SupportedPlatform"] == "macos":
            # Zig's bundled C++ debug entries cannot be resolved by dsymutil.
            run("xcrun", "strip", "-S", framework / library["LibraryIdentifier"] / library["LibraryPath"])
    run(ROOT / "scripts/generate-project.sh")
    derived = ROOT / ".build/DerivedData"
    derived.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macos-release-", dir=ROOT / ".build") as directory:
        temporary = Path(directory)
        archive = temporary / "Pocahontas.xcarchive"
        build = ("xcodebuild", "-project", "pocahontas.xcodeproj", "-scheme", "pocahontas-macOS",
                 "-configuration", "Release", "-destination", "generic/platform=macOS",
                 "-derivedDataPath", derived, "-archivePath", archive, "-disableAutomaticPackageResolution",
                 "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_STYLE=Manual",
                 f"DEVELOPMENT_TEAM={team}", f"CODE_SIGN_IDENTITY={identity}",
                 "OTHER_CODE_SIGN_FLAGS=--timestamp")
        targets = json.loads(run(*build, "-showBuildSettings", "-json", capture=True))
        settings = next(target["buildSettings"] for target in targets if target["target"] == "pocahontas-macOS")
        run(*build, "archive")
        app = archive / "Products/Applications/Pocahontas.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        validate_bundle_info(info, settings)
        if run("lipo", "-archs", app / "Contents/MacOS/Pocahontas", capture=True).strip() != "arm64":
            raise ValueError("Expected an Apple Silicon application.")
        copy_notices(app / "Contents/Resources/Notices", derived)
        run("codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
            "--preserve-metadata=identifier,entitlements,requirements", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        notarize(app, temporary)
        output = Path(os.environ.get("OUTPUT_DIR", str(Path.home() / "Pocahontas-builds"))).expanduser()
        final = write_package(app, output, source)
        print(f"Packaged {final}")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"Signed and notarized Apple Silicon package: `{final}`\n\nCommit: `{source}`\n")


if __name__ == "__main__":
    try:
        package()
    except subprocess.CalledProcessError as error:
        print(error.stderr or error.stdout or str(error), file=sys.stderr)
        sys.exit(error.returncode)
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
