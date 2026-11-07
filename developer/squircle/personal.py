#!/usr/bin/env python3
"""Generate or archive/export a personal Debug app locally, with no service calls."""
import argparse
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid
from configuration import ROOT, load, personal_spec

HERE = Path(__file__).resolve().parent
METHODS = {"development", "debugging", "ad-hoc", "release-testing"}


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def export_options(path, config):
    options = plistlib.loads(Path(path).read_bytes())
    if options.get("method") not in METHODS:
        raise ValueError("only explicit personal export methods are allowed")
    if options.get("teamID") != config["team_id"] or options.get("signingStyle") != "manual":
        raise ValueError("export requires matching teamID and manual signingStyle")
    if set(options.get("provisioningProfiles", {})) != {config["bundle_id"], config["bundle_id"] + ".widgets"}:
        raise ValueError("export needs exactly the matching app and widget profiles")
    certificate = options.get("signingCertificate", "")
    if len(certificate) != 40 or any(c not in "0123456789ABCDEF" for c in certificate):
        raise ValueError("signingCertificate must be an explicit uppercase SHA-1 fingerprint")
    if options.get("destination", "export") != "export":
        raise ValueError("upload is disabled")
    return options


def profile(path, bundle, config, options):
    result = run(["security", "cms", "-D", "-i", path], capture_output=True)
    data = plistlib.loads(result.stdout)
    ent = data.get("Entitlements", {})
    prefix = data.get("ApplicationIdentifierPrefix", [])
    if len(prefix) != 1 or ent.get("application-identifier") != prefix[0] + "." + bundle:
        raise ValueError("profile must match the exact bundle ID")
    if data.get("TeamIdentifier") != [config["team_id"]] or ent.get("com.apple.developer.team-identifier") != config["team_id"]:
        raise ValueError("profile team mismatch")
    if data.get("ExpirationDate", datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError("profile expired")
    if not data.get("ProvisionedDevices") or data.get("ProvisionsAllDevices"):
        raise ValueError("personal profiles must explicitly cover devices")
    if bool(ent.get("get-task-allow")) != (options["method"] in {"development", "debugging"}):
        raise ValueError("profile does not match the personal export method")
    if ent.get("com.apple.security.application-groups") != [config["app_group"]]:
        raise ValueError("profile must contain only the configured App Group")
    fingerprints = {hashlib.sha1(cert).hexdigest().upper() for cert in data.get("DeveloperCertificates", [])}
    if options["signingCertificate"] not in fingerprints:
        raise ValueError("profile does not contain the selected signing certificate")
    if options["provisioningProfiles"][bundle] != data.get("UUID"):
        raise ValueError("export mapping must use this profile UUID")
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", data["UUID"]):
        raise ValueError("invalid provisioning profile UUID")
    return data["UUID"]


def entitlements(app):
    return plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", app], capture_output=True).stdout)


def verify(app, config):
    run(["codesign", "--verify", "--deep", "--strict", app])
    widgets = list((app / "PlugIns").glob("*.appex"))
    if len(widgets) != 1:
        raise ValueError("expected exactly one widget extension")
    result = []
    for target, bundle in [(app, config["bundle_id"]), (widgets[0], config["bundle_id"] + ".widgets")]:
        info = plistlib.loads((target / "Info.plist").read_bytes())
        ent = entitlements(target)
        if info.get("CFBundleIdentifier") != bundle or info.get("AwesoMuxAppGroup") != config["app_group"]:
            raise ValueError("bundle/App Group runtime configuration mismatch")
        if ent.get("com.apple.developer.team-identifier") != config["team_id"] or not ent.get("application-identifier", "").endswith("." + bundle):
            raise ValueError("signed team/application mismatch")
        if ent.get("com.apple.security.application-groups") != [config["app_group"]]:
            raise ValueError("signed App Group mismatch")
        result.append(ent)
    return result


def generate(config, profiles=None, identity=None):
    # Retain the full native receipt and dependency-lock validation.
    run(["zsh", "script/generate-watch.sh"], cwd=ROOT / "ios")
    spec = personal_spec(config)
    if profiles:
        for bundle, profile_id in profiles.items():
            marker = "PRODUCT_BUNDLE_IDENTIFIER: " + bundle + "\n"
            if spec.count(marker) != 1:
                raise ValueError("target signing layout changed")
            spec = spec.replace(marker, marker + "        PROVISIONING_PROFILE_SPECIFIER: " + profile_id + "\n")
        spec = spec.replace("CODE_SIGN_STYLE: Automatic", 'CODE_SIGN_STYLE: Manual\n    CODE_SIGN_IDENTITY: "' + identity + '"')
    destination = ROOT / "ios/project.squircle.local.yml"
    destination.write_text(spec)
    package = (ROOT / "ios/build/diagnostics-native/local-package-path.txt").read_text().strip()
    run(["xcodegen", "generate", "--spec", destination], cwd=ROOT / "ios", env={**os.environ, "GHOSTTY_LOCAL_PACKAGE": package})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["generate", "export"])
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--prepared", type=Path)
    parser.add_argument("--export-options", type=Path)
    parser.add_argument("--app-profile", type=Path)
    parser.add_argument("--widget-profile", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    config = load(args.config)
    if args.action == "generate":
        generate(config)
        return
    for name in ["prepared", "export_options", "app_profile", "widget_profile", "output"]:
        if getattr(args, name) is None:
            parser.error("export requires --" + name.replace("_", "-"))
    if args.output.exists() or args.output.is_symlink():
        parser.error("output must be a new directory")
    options = export_options(args.export_options, config)
    profiles = {bundle: profile(path, bundle, config, options) for bundle, path in [
        (config["bundle_id"], args.app_profile), (config["bundle_id"] + ".widgets", args.widget_profile)]}
    prepared = args.prepared.resolve()
    if json.loads((prepared / "companion-config.json").read_text()) != config:
        raise ValueError("prepared overlay belongs to a different configuration")
    run([sys.executable, HERE / "check-invariants.py", prepared])
    generate(config, profiles, options["signingCertificate"])
    output = args.output.resolve()
    output.mkdir(mode=0o700)
    archive = output / "personal.xcarchive"
    run(["xcodebuild", "-project", ROOT / "ios/AwesoMuxCompanion.xcodeproj", "-scheme", "AwesoMuxCompanion",
         "-configuration", "Debug", "-destination", "generic/platform=iOS", "-archivePath", archive,
         "-derivedDataPath", output / "DerivedData", "INFOPLIST_KEY_AwesoMuxPersonalDebug=YES", "archive"])
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("archive must contain exactly one app")
    app = apps[0]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if str(info.get("AwesoMuxPersonalDebug")).upper() not in {"YES", "TRUE"}:
        raise ValueError("archive has no personal Debug marker")
    before = verify(app, config)
    run(["xcodegen", "generate"], cwd=prepared / "app/Squircle")
    run(["cargo", "build", "--locked", "--bin", "companion-inject"], cwd=prepared)
    build_id = str(uuid.uuid4())
    run([prepared / "target/debug/companion-inject", app, output / "cache", output / "inject.log", build_id, options["method"]],
        env={**os.environ, "SQUIRCLE_OVERLAY_PROJECT": str(prepared / "app/Squircle/Squircle.xcodeproj")})
    if verify(app, config) != before:
        raise ValueError("injection changed host or widget entitlements")
    run(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", output / "export",
         "-exportOptionsPlist", args.export_options.resolve()])
    ipas = list((output / "export").glob("*.ipa"))
    if len(ipas) != 1:
        raise ValueError("expected exactly one personal IPA")
    import zipfile
    with zipfile.ZipFile(ipas[0]) as package:
        package.extractall(output / "inspection")
    exported = list((output / "inspection/Payload").glob("*.app"))
    if len(exported) != 1:
        raise ValueError("expected exactly one exported app")
    verify(exported[0], config)
    if not (exported[0] / "Frameworks/SquircleOverlay.framework/SquircleOverlay").is_file():
        raise ValueError("export lost the overlay")
    info = plistlib.loads((exported[0] / "Info.plist").read_bytes())
    linked = run(["otool", "-L", exported[0] / info["CFBundleExecutable"]], capture_output=True).stdout
    if b"@executable_path/Frameworks/SquircleOverlay.framework/SquircleOverlay" not in linked:
        raise ValueError("export lost the overlay load command")
    if not (exported[0] / "Frameworks/SquircleOverlay.framework/CompanionSquircleNotices.txt").is_file():
        raise ValueError("export lost third-party attribution")
    if any(path.name == "client.json" for path in exported[0].rglob("*")):
        raise ValueError("export contains an embedded connection file")
    (output / "receipt.json").write_text(json.dumps({"build_id": build_id, "configuration": "Debug", "method": options["method"],
        "ipa_sha256": hashlib.sha256(ipas[0].read_bytes()).hexdigest()}, indent=2) + "\n")
    print("Personal Debug export verified. No upload, install, service or provider changes.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError):
        sys.exit("Personal setup failed; inspect the local build log. No install/upload attempted.")
