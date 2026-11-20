#!/usr/bin/env bash
# Toolchain for the arm64/macOS 11 candidate. The host's precompiled Homebrew
# standard library can have the host OS as its minimum despite the target flags.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -m) == arm64 && $(uname -s) == Darwin ]]
cache="$root/build/native-migration/toolchains"
version=1.91.1
target=aarch64-apple-darwin
destination="$cache/rust-$version-$target"
if [[ ! -f "$destination/.verified-packages" ]]; then
    mkdir -p "$cache"
    work=$(mktemp -d "$cache/setup.XXXXXXXX")
    printf 'toolchain setup pid=%d scratch=%s\n' "$$" "$work" >> "$cache/resources.log"
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 130' INT TERM HUP
    mkdir -p "$work/prefix"
    for component in rustc cargo rust-std; do
        case "$component" in
            rustc) digest=327c9017195b4ad0465ab6b1f1036377415cc6dc3612301af6ed9e3414ff53c8 ;;
            cargo) digest=f6162fbbe0a514efcbd488cf78524fe5bfbc000b197922a8ff2b7f8440fa235a ;;
            rust-std) digest=edf0e5053da34759bdbc1abc47dab7d9882c8b4c68b5fdbeb103b6a5a0d23a58 ;;
        esac
        name="$component-$version-$target"
        archive="$work/$name.tar.xz"
        if [[ -f "$cache/archives/$name.tar.xz" ]]; then
            archive="$cache/archives/$name.tar.xz"
        else
            curl --fail --silent --show-error --location --retry 2 "https://static.rust-lang.org/dist/2025-11-10/$name.tar.xz" -o "$archive"
        fi
        printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c - >&2
        tar -xf "$archive" -C "$work"
        "$work/$name/install.sh" --disable-ldconfig --prefix="$work/prefix" >&2
        printf '%s  %s\n' "$digest" "$name" >> "$work/components"
    done
    cp "$work/components" "$work/prefix/.verified-packages"
    # Publish only a completed toolchain, including concurrent independent builds.
    python3 - "$work/prefix" "$destination" <<'PY'
import os, pathlib, sys
source, destination = sys.argv[1:]
try:
    os.rename(source, destination)
except OSError:
    if not pathlib.Path(destination, ".verified-packages").is_file():
        raise
PY
fi
printf '%s\n' "$destination"
