#!/usr/bin/env bash
# Create distribution files from the checked-out release source.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
release=${1:?Usage: bash script/package_native_release.sh vVERSION-beta.N}
version=$(sed -n 's/^version=//p' src/version.properties)
[[ $release =~ ^v[0-9]+[.][0-9]+[.][0-9]+-beta[.][0-9]+$ && $release == "v$version"-beta.* ]]
[[ -z $(git status --porcelain) ]] || { echo 'Use a clean release checkout.' >&2; exit 1; }
commit=$(git rev-parse HEAD)
mkdir -p dist
output=$(mktemp -d "$root/dist/native-$release.XXXXXXXX")
stage="$output/staging"
mkdir "$stage"
printf 'pid=%s\nowned staging=%s\ncleanup=remove staging on exit\n' "$$" "$stage" > "$output/resources.txt"
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 130' INT TERM HUP

app=$(bash script/build_native_candidate.sh)
[[ $(git rev-parse HEAD) == "$commit" && -z $(git status --porcelain) ]]
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $app_version == "$version" ]]
ditto --noqtn --norsrc "$app" "$stage/HoDoKu Native.app"
/usr/bin/codesign --verify --deep --strict "$stage/HoDoKu Native.app"
cp INSTALL.md "$stage/安装说明.md"
cp COPYING "$stage/COPYING"
cp UPSTREAM.md THIRD_PARTY_NOTICES.md "$stage/"
ln -s /Applications "$stage/Applications"

name="HoDoKu-Native-${release#v}"
dmg="$name-AppleSilicon.dmg"
source="$name-source.tar.gz"
git -c tar.umask=0022 archive --format=tar --prefix="$name/" "$commit" | gzip -n > "$output/$source"
hdiutil create -volname 'HoDoKu Native' -srcfolder "$stage" -format UDZO "$output/$dmg" >&2
hdiutil verify "$output/$dmg" >&2
(cd "$output" && shasum -a 256 "$dmg" "$source" > SHA256SUMS.txt)
printf '%s\n' "$commit" > "$output/source-commit.txt"
printf '%s\n' "$output"
