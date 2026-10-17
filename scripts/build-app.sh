#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${CONFIGURATION:-release}

cd "$project_dir"
# Build logs go to stderr so stdout carries exactly one thing: the app path.
swift build -c "$configuration" --product MusicRateSwitcher >&2
binary_dir=$(swift build -c "$configuration" --show-bin-path 2>/dev/null | tail -1)

# Output goes to a hidden directory by default: an app bundle sitting in a
# Spotlight-indexed folder gets registered with LaunchServices, and macOS then
# offers two copies of the app (this build and the installed one).
out_dir=${OUT_DIR:-"$project_dir/.build/app"}
app_dir="$out_dir/MusicRateSwitcher.app"
contents_dir="$app_dir/Contents"

if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_dir/MusicRateSwitcher" "$contents_dir/MacOS/MusicRateSwitcher"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
chmod +x "$contents_dir/MacOS/MusicRateSwitcher"

# Prefer the stable self-signed identity (see create-signing-cert.sh) so macOS
# privacy grants survive updates; fall back to ad-hoc for local builds.
identity=${SIGN_IDENTITY:-"MusicRateSwitcher Self-Signed"}
if security find-certificate -c "$identity" >/dev/null 2>&1; then
    # securityd occasionally answers errSecInternalComponent; a retry clears it.
    for attempt in 1 2 3; do
        codesign --force --sign "$identity" "$app_dir" && break
        [[ $attempt == 3 ]] && exit 1
        sleep 1
    done
else
    echo "warning: signing identity \"$identity\" not found; using ad-hoc signature." >&2
    echo "         Privacy grants will not survive updates. Run scripts/create-signing-cert.sh." >&2
    codesign --force --sign - "$app_dir"
fi

# Print what actually signed the bundle: the designated requirement is what
# macOS keys privacy grants on, so it must not change between releases.
echo "signed by: $(codesign -dv --verbose=2 "$app_dir" 2>&1 | sed -n 's/^Authority=//p' | head -1)" >&2
echo "requirement: $(codesign -dr - "$app_dir" 2>&1 | tail -1)" >&2

echo "$app_dir"
