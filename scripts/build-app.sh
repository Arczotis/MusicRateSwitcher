#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${CONFIGURATION:-release}

cd "$project_dir"
swift build -c "$configuration" --product MusicRateSwitcher
binary_dir=$(swift build -c "$configuration" --show-bin-path)

dist_dir="$project_dir/dist"
app_dir="$dist_dir/MusicRateSwitcher.app"
contents_dir="$app_dir/Contents"

if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_dir/MusicRateSwitcher" "$contents_dir/MacOS/MusicRateSwitcher"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
chmod +x "$contents_dir/MacOS/MusicRateSwitcher"

codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
