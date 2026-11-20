#!/usr/bin/env bash
# Build, test and sign an independent local candidate. No application is launched or installed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]]
base="$root/build/native-migration"
mkdir -p "$base/candidates"
run=$(mktemp -d "$base/candidates/run.XXXXXXXX")
printf 'Build evidence: %s\n' "$run" >&2
work="$run/work"
printf 'process=%s\nscratch=%s\n' "$$" "$work" > "$run/resources.txt"
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$work/home" "$work/tmp" "$work/profile"
rust=$(bash script/prepare_native_rust.sh)
export RUSTC="$rust/bin/rustc"
export RUSTDOC="$rust/bin/rustdoc"
export CARGO_HOME="$base/cargo-home"
export MACOSX_DEPLOYMENT_TARGET=11.0
export SDKROOT
SDKROOT=$(python3 - "${SDKROOT:-}" "$(xcrun --sdk macosx --show-sdk-path)" <<'PY'
from pathlib import Path
import json, sys
candidates = [Path(sys.argv[1])] if sys.argv[1] else [
    Path(sys.argv[2]), Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")]
for sdk in candidates:
    settings = sdk / "SDKSettings.json"
    if settings.exists():
        targets = json.loads(settings.read_text())["SupportedTargets"]["macosx"]
        if "11.0" in targets.get("ValidDeploymentTargets", []):
            print(sdk.resolve())
            break
else:
    sys.exit("Select a macOS SDK that supports deployment target 11.0 via SDKROOT")
PY
)
export CARGO_TARGET_DIR="$base/official-rust-target"
swift=(xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos11.0
       -sdk "$SDKROOT" -module-cache-path "$base/swift-module-cache" -Xlinker -fatal_warnings)
# Keep the checks, compiler and resource copy on one set of build inputs.
mkdir -p "$work"/{board,app,engine,board-tests}
cp native/board/Sources/*.swift "$work/board/"
cp native/app/Sources/*.swift "$work/app/"
cp native/engine/include/* "$work/engine/"
cp native/app/Resources/{training-names.json,Swift-LICENSE.txt} "$work/"
cp native/app/Artwork/AppIcon.swift native/app/Info.plist "$work/"
board_tests=(native/board/Tests/{CombinedChecks,BoardChecks,ToolChecks,InkReasoningChecks,ChainToolChecks,AnnotationOverlayChecks,ReplayRecordingChecks,ReplayWorkbenchChecks,NativeStorageChecks,WorkspaceChecks,WorkspaceSharingChecks,FilterOptionsChecks}.swift)
cp "${board_tests[@]}" "$work/board-tests/"
cp native/app/Tests/CountChecks.swift "$work/"
cp -R native/app/Resources/{en,de,zh-Hans}.lproj "$work/"
ffi=(-I "$work/engine" -L "$work/engine" -lhodoku_engine)
{
    xcrun swiftc --version
    "$RUSTC" --version --verbose
    "$rust/bin/cargo" --version
    printf 'SDK=%s\n' "$SDKROOT"
    sw_vers
    /usr/sbin/sysctl -n machdep.cpu.brand_string
    xcodebuild -version
    shasum -a 256 "$SDKROOT/SDKSettings.json"
    cat "$rust/.verified-packages"
} > "$run/toolchain.txt"
"$rust/bin/cargo" test --locked --offline --manifest-path native/engine/Cargo.toml > "$run/rust-tests.log" 2>&1
"$rust/bin/cargo" build --release --locked --offline --manifest-path native/engine/Cargo.toml
cp "$CARGO_TARGET_DIR/release/libhodoku_engine.a" "$work/engine/"
(cd "$work" && shasum -a 256 board/*.swift app/*.swift engine/* *.lproj/Localizable.strings training-names.json Swift-LICENSE.txt AppIcon.swift Info.plist) > "$run/build-inputs.sha256"
"${swift[@]}" "$work/app/SolutionCounter.swift" "$work/CountChecks.swift" "${ffi[@]}" -o "$work/count-checks"
"$work/count-checks" native/engine/verification/java-recorded.jsonl > "$run/swift-count-checks.log"
"${swift[@]}" -whole-module-optimization -D COMBINED_BOARD_CHECKS "$work/board/"*.swift "$work/board-tests/"*.swift "${ffi[@]}" -o "$work/board-checks"
env CFFIXED_USER_HOME="$work/home" TMPDIR="$work/tmp" HODOKU_NATIVE_DATA_DIR="$work/profile" \
    "$work/board-checks" native/board/Tests/ChainToolJava.tsv > "$run/board-checks.log"
app="$run/HoDoKu Native.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
# Swift's escaping-closure checks encode the spelling and length of the source path.
# A relative input list and no linker OSO debug map keep temporary paths out of the binary.
(cd "$work" && "${swift[@]}" -whole-module-optimization board/*.swift app/*.swift \
    -I engine -L engine -lhodoku_engine -Xlinker -S -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$contents/MacOS/HoDoKuNative")
# SwiftUI imports main-actor metadata. Big Sur obtains the compatibility runtime
# from the bundle; newer systems can resolve it through their system Swift path.
toolchain_usr=$(dirname "$(dirname "$(xcrun --find swiftc)")")
mkdir -p "$work/swift-runtime" "$contents/Frameworks"
xcrun swift-stdlib-tool --copy --platform macosx --source-libraries "$toolchain_usr/lib/swift-5.5/macosx" \
    --scan-executable "$contents/MacOS/HoDoKuNative" --destination "$work/swift-runtime"
for library in "$work/swift-runtime"/*.dylib; do
    [[ -f "$library" ]] || continue
    target="$contents/Frameworks/${library##*/}"
    if [[ $(lipo -archs "$library") == arm64 ]]; then cp "$library" "$target"
    else lipo "$library" -thin arm64 -output "$target"; fi
    codesign --force --sign - "$target"
done
cp "$work/Info.plist" "$contents/Info.plist"
"${swift[@]}" "$work/AppIcon.swift" -o "$work/draw-icon"
"$work/draw-icon" "$work/HoDoKu.iconset"
/usr/bin/iconutil -c icns "$work/HoDoKu.iconset" -o "$contents/Resources/HoDoKu.icns"
cp "$work/HoDoKu.iconset/icon_128x128@2x.png" "$run/app-icon.png"
cp "$work"/{training-names.json,Swift-LICENSE.txt} "$contents/Resources/"
cp -R "$work"/{en,de,zh-Hans}.lproj "$contents/Resources/"
release=$(sed -n 's/^version=//p' src/version.properties)
[[ $release =~ ^[0-9]+([.][0-9]+){1,2}$ ]]
/usr/bin/plutil -insert CFBundleShortVersionString -string "$release" "$contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$release" "$contents/Info.plist"
cp COPYING UPSTREAM.md THIRD_PARTY_NOTICES.md "$contents/Resources/"
cp "$rust/share/doc/rust/COPYRIGHT-library.html" "$contents/Resources/Rust-COPYRIGHT-library.html"
/usr/bin/codesign --force --sign - "$app"
python3 native/app/audit.py "$app" > "$run/bundle-audit.json"
xcrun vtool -show-build "$contents/MacOS/HoDoKuNative" > "$run/platform.txt"
(cd "$app" && find Contents -type f -print | LC_ALL=C sort | while IFS= read -r entry; do shasum -a 256 "$entry"; done) > "$run/SHA256SUMS"
cat "$run/swift-count-checks.log" "$run/board-checks.log" >&2
printf '%s\n' "$app"
