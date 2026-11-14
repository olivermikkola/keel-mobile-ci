#!/usr/bin/env python3
"""Verify a build-only iPhone archive on macOS; never uploads or changes keys."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

BUNDLE_ID = "com.olivermikkola.keelmobile"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, f"Signed archive check: {args[0]} failed ({result.returncode}).")
    return result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit), "Expected the exact source commit SHA.")
    require(args.ipa.is_file(), "No signed IPA was produced.")
    with zipfile.ZipFile(args.ipa) as archive:
        entries = archive.infolist()
        require(len(entries) <= 20_000 and sum(item.file_size for item in entries) <= 2_147_483_648,
                "Signed archive exceeds the expected package bounds.")
        require(all(not Path(item.filename).is_absolute() and ".." not in Path(item.filename).parts for item in entries),
                "Invalid archive entry path.")
    with tempfile.TemporaryDirectory(prefix="keel-signed-proof-") as temporary:
        folder = Path(temporary)
        # ditto preserves executable modes and framework structure for codesign.
        command("ditto", "-x", "-k", str(args.ipa.resolve()), str(folder))
        apps = list((folder / "Payload").glob("*.app"))
        require(len(apps) == 1, "Expected one iPhone application in the IPA.")
        app = apps[0]
        with (app / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        require(info.get("CFBundleIdentifier") == BUNDLE_ID, "The signed package has the wrong bundle identifier.")
        require(info.get("ITSAppUsesNonExemptEncryption") is False,
                "The IPA is missing the explicit exempt-encryption declaration; Apple would block TestFlight testing.")
        require("iPhoneOS" in info.get("CFBundleSupportedPlatforms", []), "The package is not built for iPhoneOS.")
        with (app / "PrivacyInfo.xcprivacy").open("rb") as handle:
            packaged_privacy = plistlib.load(handle)
        source_privacy = Path(__file__).resolve().parents[1] / "Resources" / "PrivacyInfo.xcprivacy"
        with source_privacy.open("rb") as handle:
            expected_privacy = plistlib.load(handle)
        require(packaged_privacy == expected_privacy, "The IPA privacy manifest does not match the current source resource.")
        executable = info.get("CFBundleExecutable", "")
        require(executable and Path(executable).name == executable, "Invalid application executable.")
        architectures, _ = command("lipo", "-archs", str(app / executable))
        require(b"arm64" in architectures.split(), "The signed package is missing arm64 device code.")
        command("codesign", "--verify", "--deep", "--strict", str(app))
        display_out, display_error = command("codesign", "--display", "--verbose=4", str(app))
        display = display_out + display_error
        require(b"Authority=" in display and b"Signature=adhoc" not in display,
                "The package is not signed with a certificate identity.")
        profile_data, _ = command("security", "cms", "-D", "-i", str(app / "embedded.mobileprovision"))
        profile = plistlib.loads(profile_data)
        expiration = profile.get("ExpirationDate")
        require(isinstance(expiration, datetime.datetime), "The provisioning profile has no expiration date.")
        expiration = expiration.replace(tzinfo=datetime.timezone.utc) if expiration.tzinfo is None else expiration
        require(expiration > datetime.datetime.now(datetime.timezone.utc), "The provisioning profile has expired.")
        require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
                "Expected an App Store distribution profile.")
        teams = profile.get("TeamIdentifier", [])
        require(len(teams) == 1 and isinstance(teams[0], str), "The provisioning profile has no single team identity.")
        identifier = teams[0] + "." + BUNDLE_ID
        require(profile.get("Entitlements", {}).get("application-identifier") == identifier and
                not profile.get("Entitlements", {}).get("get-task-allow", False),
                "The profile is not the expected distribution identity.")
        entitlements_data, _ = command("codesign", "--display", "--entitlements", ":-", str(app))
        entitlements = plistlib.loads(entitlements_data)
        require(entitlements.get("application-identifier") == identifier and not entitlements.get("get-task-allow", False),
                "The signed application entitlements do not match distribution.")
        require(("TeamIdentifier=" + teams[0]).encode() in display, "The signing team does not match the provisioning profile.")
        digest = hashlib.sha256()
        with args.ipa.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1_048_576), b""):
                digest.update(chunk)
        proof = {
            "source_commit": args.source_commit,
            "bundle_id": BUNDLE_ID,
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "distribution": "app_store",
            "architectures": architectures.decode().strip().split(),
            "profile_expires": expiration.isoformat(),
            "ipa_sha256": digest.hexdigest(),
            "code_signatures_verified": True,
            "privacy_manifest_matches_source": True,
            "app_store_connect_uploaded": False,
        }
        Path("artifacts").mkdir(exist_ok=True)
        Path("artifacts/signed-ipa-proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        print("Signed archive proof: correct bundle, arm64 iPhoneOS, source privacy manifest, distribution profile/entitlements and code signatures verified. IPA was not uploaded to App Store Connect.")


if __name__ == "__main__":
    main()
