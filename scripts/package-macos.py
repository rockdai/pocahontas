import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
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
        raise ValueError(f"Notarization was not accepted: {result.get('status')}; submission {result.get('id')}")
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
        run("xcodebuild", "-project", "pocahontas.xcodeproj", "-scheme", "pocahontas-macOS",
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-derivedDataPath", derived, "-archivePath", archive, "-disableAutomaticPackageResolution",
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_STYLE=Manual",
            f"DEVELOPMENT_TEAM={team}", f"CODE_SIGN_IDENTITY={identity}",
            "OTHER_CODE_SIGN_FLAGS=--timestamp", "archive")
        app = archive / "Products/Applications/Pocahontas.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "com.rockdai.pocahontas.mac":
            raise ValueError("Unexpected application bundle identifier.")
        if run("lipo", "-archs", app / "Contents/MacOS/Pocahontas", capture=True).strip() != "arm64":
            raise ValueError("Expected an Apple Silicon application.")
        run("codesign", "--verify", "--deep", "--strict", app)
        notarize(app, temporary)
        stage = temporary / "Pocahontas"
        stage.mkdir()
        run("ditto", app, stage / "Pocahontas.app")
        copy_notices(stage, derived)
        (stage / "使用说明.txt").write_text(
            f"Pocahontas — Apple Silicon，macOS 14 或更新版本。\n源码版本：{source}\n"
            "已使用 Developer ID 签名并完成 Apple 公证。\n"
            "解压后将 Pocahontas.app 拖入‘应用程序’，双击运行。\n", encoding="utf-8")
        output = Path(os.environ.get("OUTPUT_DIR", str(Path.home() / "Pocahontas-builds"))).expanduser()
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".packaging-", dir=output) as staging_output:
            pending = Path(staging_output) / f"Pocahontas-AppleSilicon-{source[:12]}.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", stage, pending)
            verified = temporary / "verify"
            run("ditto", "-x", "-k", pending, verified)
            verified_app = verified / "Pocahontas/Pocahontas.app"
            run("codesign", "--verify", "--deep", "--strict", verified_app)
            run("xcrun", "stapler", "validate", verified_app)
            checksum = hashlib.sha256(pending.read_bytes()).hexdigest()
            final = output / pending.name
            pending.replace(final)
            final.with_suffix(".zip.sha256").write_text(f"{checksum}  {final.name}\n")
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
