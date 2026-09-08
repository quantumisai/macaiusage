#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    echo "Build and verify a universal ZIP using the version in Resources/Info.plist." >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Packaging QuotaBar requires macOS." >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a release version like 1.0.0 in Resources/Info.plist." >&2
    exit 1
fi

"$project_dir/scripts/build-app.sh" --universal

app_bundle="$project_dir/dist/QuotaBar.app"
archive_name="QuotaBar-v$version-universal.zip"
archive_path="$project_dir/dist/$archive_name"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-release.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT

# Remove local filesystem metadata before publishing. Signing remains ad hoc:
# Developer ID signing and Apple notarization require the maintainer's account.
xattr -cr "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
rm -f "$archive_path"
ditto -c -k --keepParent --sequesterRsrc "$app_bundle" "$archive_path"

# Validate the artifact people will actually download, including both slices.
ditto -x -k "$archive_path" "$verification_dir"
extracted_app="$verification_dir/QuotaBar.app"
executable="$extracted_app/Contents/MacOS/QuotaBar"
codesign --verify --deep --strict "$extracted_app"
lipo "$executable" -verify_arch arm64 x86_64
minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$extracted_app/Contents/Info.plist")"
if [[ "$minimum_version" != "14.0" ]]; then
    echo "Unexpected minimum macOS version: $minimum_version" >&2
    exit 1
fi
for architecture in arm64 x86_64; do
    binary_minimum="$(otool -arch "$architecture" -l "$executable" | awk '/LC_BUILD_VERSION/ { in_build_version=1; next } in_build_version && $1 == "minos" { print $2; in_build_version=0 }')"
    if [[ "$binary_minimum" != "14.0" ]]; then
        echo "Unexpected $architecture minimum macOS version: $binary_minimum" >&2
        exit 1
    fi
done

(
    cd "$project_dir/dist"
    shasum -a 256 "$archive_name" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
echo "Packaged $archive_path"
echo "Verified: Apple silicon + Intel; macOS 14.0 minimum; ad-hoc code signature."
echo "This archive is not Developer ID signed or notarized."
