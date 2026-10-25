"""Package an unsigned iphoneos app for local re-signing with Sideloadly."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def package(app, output, commit):
    app = app.resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError("--app must be an Xcode-built .app directory")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if (info.get("DTPlatformName") != "iphoneos"
            or info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]):
        raise ValueError("An actual iPad/iPhone build is required; simulator apps cannot be installed")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("The app executable is missing")
    if info.get("UIDeviceFamily") != [2]:
        raise ValueError("Expected the SORI iPad app")
    if (app / "embedded.mobileprovision").exists():
        raise ValueError("Expected the unsigned CI app, without a provisioning profile")
    # Debug LAN access is required by the current Windows development server.
    if not info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"):
        raise ValueError("Expected the Debug app that supports the local HTTP server")

    required = ["sori-piano-v1.sf2", "sori-piano-v2.sf2", "instrument-profile-v2.json", "sori-click-v1.wav", "practice-catalog.json", "GeneralUser-GS.sf2", "instrument-bank.json", "generaluser-license.txt", "instruments.json", "engraving-manifest.json"]
    for number in (1, 2, 3):
        required += [f"excerpt-{number}-v2-main.mxl", f"excerpt-{number}-v2-scale.mxl", f"excerpt-{number}-reference-v1.pngdata"]
    for name in required:
        bundled = app / name
        canonical = ROOT / "frontend/IPadApp/IPadApp/Resources" / name
        if not bundled.is_file() or bundled.read_bytes() != canonical.read_bytes():
            raise ValueError(f"Missing or changed bundled resource: {name}")

    output = output.resolve()
    if output == app or app in output.parents:
        raise ValueError("Output must be outside the app bundle")
    files = sorted(app.rglob("*"))
    if any(path.is_symlink() for path in files):
        raise ValueError("Unexpected symlink in the SORI app bundle")
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / "SORI-iPad-unsigned.ipa"
    temporary = output / "SORI-iPad-unsigned.ipa.tmp"
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in files:
                if not path.is_file():
                    continue
                relative = path.relative_to(app)
                entry = zipfile.ZipInfo.from_file(path, f"Payload/{app.name}/{relative.as_posix()}")
                # Keep executable permissions through the outer GitHub artifact ZIP.
                mode = stat.S_IMODE(path.stat().st_mode)
                if relative.as_posix() == executable:
                    mode |= 0o111
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA archive integrity check failed")
        temporary.replace(ipa)
    finally:
        temporary.unlink(missing_ok=True)

    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    manifest = {
        "commit": commit,
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "platform": "iphoneos",
        "configuration": "Debug",
        "signing": "unsigned; re-sign locally with Sideloadly",
        "file": ipa.name,
        "bytes": ipa.stat().st_size,
        "sha256": digest,
    }
    (output / "build-info.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
    (output / "INSTALL-WINDOWS.md").write_bytes((ROOT / "docs/WINDOWS-IPAD.md").read_bytes())
    print(f"Packaged {ipa.name}: {ipa.stat().st_size} bytes, SHA-256 {digest}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("## iPad installation package\n\n")
            stream.write("Download **SORI-iPad-install** from this run's Artifacts, extract the ZIP, ")
            stream.write("and open **INSTALL-WINDOWS.md**. The IPA requires local signing with Sideloadly.\n\n")
            stream.write(f"Source commit: {commit}. Device installation is a separate verification step.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/ipad")
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "local"))
    args = parser.parse_args()
    try:
        package(args.app, args.output, args.commit)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"IPA packaging failed: {error}\n")


if __name__ == "__main__":
    main()
