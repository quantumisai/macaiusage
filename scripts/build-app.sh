#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

universal=false
case "${1:-}" in
    --universal) universal=true; shift ;;
    --help|-h)
        echo "Usage: $0 [--universal]"
        echo "Build dist/QuotaBar.app for this Mac, or both Apple silicon and Intel."
        exit 0
        ;;
esac
if [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--universal]" >&2
    exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "QuotaBar requires macOS 14 or later." >&2
    exit 1
fi

app_bundle="$project_dir/dist/QuotaBar.app"
iconset_dir="$project_dir/.build/QuotaBar.iconset"

# Recreate the bundle so previous builds cannot leave resources or signatures.
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$iconset_dir"
if [[ "$universal" == true ]]; then
    binaries=()
    for architecture in arm64 x86_64; do
        build_dir="$project_dir/.build/release-$architecture"
        build_options=(
            --configuration release
            --scratch-path "$build_dir"
            --triple "$architecture-apple-macosx14.0"
            -debug-info-format none
        )
        swift build "${build_options[@]}" --product QuotaBar
        binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
        binaries+=("$binary_dir/QuotaBar")
    done
    lipo -create "${binaries[@]}" -output "$app_bundle/Contents/MacOS/QuotaBar"
    chmod 755 "$app_bundle/Contents/MacOS/QuotaBar"
    lipo "$app_bundle/Contents/MacOS/QuotaBar" -verify_arch arm64 x86_64
else
    swift build --configuration release --product QuotaBar
    binary_dir="$(swift build --configuration release --show-bin-path)"
    install -m 755 "$binary_dir/QuotaBar" "$app_bundle/Contents/MacOS/QuotaBar"
fi
# Debug information can contain local build paths and is unnecessary in the app.
strip -S "$app_bundle/Contents/MacOS/QuotaBar"
install -m 644 "$project_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
install -m 644 "$project_dir/LICENSE" "$app_bundle/Contents/Resources/LICENSE.txt"
swift "$project_dir/scripts/generate-icon.swift" "$iconset_dir"
iconutil --convert icns --output "$app_bundle/Contents/Resources/AppIcon.icns" "$iconset_dir"
plutil -lint "$app_bundle/Contents/Info.plist"
codesign --force --sign - --identifier com.senna.quotabar "$app_bundle"
codesign --verify --strict "$app_bundle"

echo "Built $app_bundle"
echo "Architectures: $(lipo -archs "$app_bundle/Contents/MacOS/QuotaBar")"
