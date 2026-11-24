#!/bin/bash
# Produce a verified universal DMG for the checked-out CodeShot version.
set -euo pipefail
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name}"

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build" "$root/dist"
work="$(mktemp -d "$root/build/package.XXXXXX")"
trap 'rm -rf "$work"' EXIT

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
xcodebuild -project "$root/CodeShot.xcodeproj" -scheme CodeShot -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet

app="$work/DerivedData/Build/Products/Release/CodeShot.app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
output="$root/dist/$version"
dmg="$work/CodeShot.dmg"
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/CodeShot" -verify_arch "$arch"
done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict "$app"

# Staple both tickets so an offline Mac can verify the copied app as well as the installer.
ditto -c -k --keepParent "$app" "$work/CodeShot.zip"
xcrun notarytool submit "$work/CodeShot.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose "$app"

mkdir "$work/disk"
ditto "$app" "$work/disk/CodeShot.app"
ln -s /Applications "$work/disk/Applications"
hdiutil create -volname CodeShot -srcfolder "$work/disk" -format UDZO "$dmg"
codesign --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
mkdir -p "$output"
mv "$dmg" "$output/CodeShot.dmg"
echo "Verified $output/CodeShot.dmg"
