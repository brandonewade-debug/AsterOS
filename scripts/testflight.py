#!/usr/bin/env python3
"""Archive AsterOS, or upload an existing archive. Credentials stay outside git."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--upload", action="store_true", help="Upload the existing archive using Xcode or ASC API authentication")
args = parser.parse_args()
version = json.loads((ROOT / "Config/Version.json").read_text())
release = ROOT / ".release" / f"{version['version']}-{version['build']}"
release.mkdir(parents=True, exist_ok=True)
archive = release / "AsterOS.xcarchive"
auth = []
names = ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if any(os.environ.get(n) for n in names):
    if not all(os.environ.get(n) for n in names):
        sys.exit("Set all three ASC credential variables, or unset them to use Xcode sign-in.")
    key = Path(os.environ["ASC_KEY_PATH"]).expanduser().resolve()
    if not key.is_file() or key.is_relative_to(ROOT):
        sys.exit("The ASC private key must exist outside this repository.")
    auth = ["-authenticationKeyPath", str(key), "-authenticationKeyID", os.environ["ASC_KEY_ID"],
            "-authenticationKeyIssuerID", os.environ["ASC_ISSUER_ID"]]

def run(command, name):
    log = release / f"{name}.log"
    print(f"{name}: running; log saved locally", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(f"{name} failed (exit {result.returncode}). Inspect {log}; do not share raw signing logs.")
        sys.exit(result.returncode)
    print(f"{name} succeeded", flush=True)

if args.upload:
    if not archive.is_dir():
        sys.exit("Archive first before uploading.")
    options = {
        "method": "app-store-connect", "destination": "upload",
        "signingStyle": "automatic", "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
        "testFlightInternalTestingOnly": False
    }
    options_path = release / "ExportOptions.local.plist"
    options_path.write_bytes(plistlib.dumps(options))
    run(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
         "-exportPath", str(release / "export"), "-exportOptionsPlist", str(options_path),
         "-allowProvisioningUpdates", *auth], "upload")
    print("Upload completed. Verify processing, encryption compliance, and testing notes in App Store Connect.")
else:
    if archive.exists():
        sys.exit("Archive already exists. Increment Config/Version.json for a new build or upload this archive.")
    team = os.environ.get("DEVELOPMENT_TEAM", "")
    if not team:
        sys.exit("Set DEVELOPMENT_TEAM to your Apple development team before archiving.")
    subprocess.run([sys.executable, "scripts/generate_project.py"], cwd=ROOT, check=True)
    subprocess.run([sys.executable, "scripts/prepare_framework_privacy.py"], cwd=ROOT, check=True)
    run(["xcodebuild", "archive", "-project", "AsterOS.xcodeproj", "-scheme", "AsterOS",
         "-configuration", "Release", "-destination", "generic/platform=iOS",
         "-archivePath", str(archive), "-derivedDataPath", str(release / "DerivedData"),
         f"DEVELOPMENT_TEAM={team}", "-allowProvisioningUpdates", *auth], "archive")
    app = archive / "Products/Applications/AsterOS.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleVersion"] == str(version["build"])
    assert info["CFBundleShortVersionString"] == version["version"]
    for p in [app / "PrivacyInfo.xcprivacy", app / "Frameworks/TailscaleKit.framework/PrivacyInfo.xcprivacy"]:
        assert p.is_file(), f"Missing privacy manifest: {p.name}"
        plistlib.loads(p.read_bytes())
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Verified archive {version['version']} ({version['build']}). Encryption questionnaire remains required.")
