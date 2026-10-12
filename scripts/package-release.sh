#!/bin/zsh
# Builds the app and produces distributable archives in dist/:
#   MusicRateSwitcher-v<version>-macOS.zip   (+ .sha256)
#   MusicRateSwitcher-v<version>-macOS.dmg   (+ .sha256, drag-to-Applications layout)
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
name="MusicRateSwitcher-v${version}-macOS"
dist_dir="$project_dir/dist"

./scripts/build-app.sh >/dev/null
app="$dist_dir/MusicRateSwitcher.app"

rm -f "$dist_dir/$name".{zip,dmg,zip.sha256,dmg.sha256}

ditto -c -k --sequesterRsrc --keepParent "$app" "$dist_dir/$name.zip"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "MusicRateSwitcher $version" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dist_dir/$name.dmg"

(cd "$dist_dir" && shasum -a 256 "$name.zip" > "$name.zip.sha256" && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")

ls -lh "$dist_dir/$name".*
