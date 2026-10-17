#!/bin/zsh
# Builds the app and produces distributable archives in dist/:
#   MusicRateSwitcher-v<version>-macOS.zip   (+ .sha256)
#   MusicRateSwitcher-v<version>-macOS.dmg   (+ .sha256, drag-to-Applications layout)
#
# The .app is built and archived from a temporary directory on purpose: an app
# bundle left inside dist/ is registered with LaunchServices and indexed by
# Spotlight, so macOS ends up offering two copies of the app — that build and
# the installed one.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
name="MusicRateSwitcher-v${version}-macOS"
dist_dir="$project_dir/dist"

build_stage=$(mktemp -d)
staging=$(mktemp -d)
trap 'rm -rf "$build_stage" "$staging"' EXIT

mkdir -p "$dist_dir"
app=$(OUT_DIR="$build_stage" ./scripts/build-app.sh | tail -1)

rm -f "$dist_dir/$name".{zip,dmg,zip.sha256,dmg.sha256}

ditto -c -k --sequesterRsrc --keepParent "$app" "$dist_dir/$name.zip"

cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "MusicRateSwitcher $version" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dist_dir/$name.dmg"

(cd "$dist_dir" && shasum -a 256 "$name.zip" > "$name.zip.sha256" && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")

ls -lh "$dist_dir/$name".*
