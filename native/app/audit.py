"""Check the standalone Swift app, sharing the project's Mach-O and RPATH rules."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
from audit_macos_bundle import audit, version

bundle = Path(sys.argv[1]).resolve()
report = audit(bundle, "arm64", runtime_only=True)
with (bundle / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
executable = "Contents/MacOS/" + info["CFBundleExecutable"]
runtime = "Contents/Frameworks/libswift_Concurrency.dylib"
# The compatibility runtime has separate macOS and Mac Catalyst load commands.
# Use the macOS entry for the app's floor while sharing the dependency/RPATH audit.
for path, binary in report["binaries"].items():
    out = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", bundle / path], text=True)
    minimum = re.search(r"platform MACOS\s+minos ([0-9.]+)", out)
    if minimum is None or version(minimum.group(1)) > (11, 0, 0):
        report["errors"].append(f"Invalid macOS deployment target in {path}")
    else:
        binary["minimum_macos"] = minimum.group(1)
    arches = subprocess.check_output(["/usr/bin/lipo", "-archs", bundle / path], text=True).split()
    if arches != ["arm64"]:
        report["errors"].append(f"Unexpected architecture in {path}: {arches}")
report["minimum_macos"] = max((v.get("minimum_macos", "0") for v in report["binaries"].values()), key=version, default="0")
if set(report["binaries"]) != {executable, runtime}:
    report["errors"].append("Unexpected executable or extra embedded binary")
if version(report["minimum_macos"]) != (11, 0, 0) or info["LSMinimumSystemVersion"] != "11.0":
    report["errors"].append("Inconsistent macOS deployment target")
if info["CFBundleIdentifier"] != "org.hodoku.nativecandidate":
    report["errors"].append("Unexpected candidate identifier")
resources = bundle / "Contents/Resources"
expected_files = {
    "COPYING": ROOT / "COPYING",
    "THIRD_PARTY_NOTICES.md": ROOT / "THIRD_PARTY_NOTICES.md",
    "UPSTREAM.md": ROOT / "UPSTREAM.md",
    "Swift-LICENSE.txt": ROOT / "native/app/Resources/Swift-LICENSE.txt",
    "training-names.json": ROOT / "native/app/Resources/training-names.json",
}
for language in ("zh-Hans", "en", "de"):
    name = language + ".lproj/Localizable.strings"
    expected_files[name] = ROOT / "native/app/Resources" / name
for name, source in expected_files.items():
    resource = resources / name
    if not resource.is_file() or resource.read_bytes() != source.read_bytes():
        report["errors"].append(f"Missing or mismatched resource {name}")
rust_notice = "Rust-COPYRIGHT-library.html"
if not (resources / rust_notice).is_file() or (resources / rust_notice).stat().st_size == 0:
    report["errors"].append("Missing Rust standard library notices")
icon_name = "HoDoKu.icns"
icon = resources / icon_name
if info.get("CFBundleIconFile") != icon_name or not icon.is_file():
    report["errors"].append("Missing application icon or its bundle declaration")
else:
    icon_info = subprocess.run(["/usr/bin/sips", "-g", "format", "-g", "pixelWidth", "-g", "pixelHeight", icon],
                               capture_output=True, text=True)
    properties = set(line.strip() for line in icon_info.stdout.splitlines())
    if icon_info.returncode or not {"format: icns", "pixelWidth: 1024", "pixelHeight: 1024"} <= properties:
        report["errors"].append("Invalid application icon")
entries = {str(entry.relative_to(resources)) for entry in resources.rglob("*") if entry.is_file()}
if entries != set(expected_files) | {rust_notice, icon_name}:
    report["errors"].append("Unexpected or missing files in Resources")
allowed = {executable, runtime, "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"}
allowed.update("Contents/Resources/" + name for name in (*expected_files, rust_notice, icon_name))
files = {str(item.relative_to(bundle)) for item in bundle.rglob("*") if item.is_file() or item.is_symlink()}
if files != allowed:
    report["errors"].append(f"Bundle inventory mismatch: missing {sorted(allowed - files)}, extra {sorted(files - allowed)}")
report["resources"] = sorted(entries)
signature = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)])
if signature.returncode:
    report["errors"].append("Signature verification failed")
report["passed"] = not report["errors"]
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if report["passed"] else 1)
