#!/bin/bash
# Produce a verified universal DMG and a signed Sparkle feed for GitHub Releases.
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
mkdir "$work/release"
dmg="$work/release/CodeShot.dmg"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
tools="$work/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
account=com.brianrenshaw.CodeShot
public_key="$("$tools/generate_keys" --account "$account" -p)"
if [[ "$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist")" != "$public_key" ]]; then
  echo "The CodeShot Sparkle key in Keychain must match the app's SUPublicEDKey." >&2
  exit 1
fi
for arch in arm64 x86_64; do
  lipo "$app/Contents/MacOS/CodeShot" -verify_arch "$arch"
  lipo "$sparkle/Sparkle" -verify_arch "$arch"
done
sign=(codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
"${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Versions/B/Autoupdate"
"${sign[@]}" "$sparkle/Versions/B/Updater.app"
"${sign[@]}" "$sparkle"
"${sign[@]}" "$app"
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
releases="https://github.com/brianrenshaw/code-shot/releases"
"$tools/generate_appcast" --account "$account" --maximum-deltas 0 \
  --download-url-prefix "$releases/download/v$version/" \
  --full-release-notes-url "$releases/tag/v$version" "$work/release"
feed="$work/release/appcast.xml"
"$tools/sign_update" --account "$account" --verify "$feed"
signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$feed")"
"$tools/sign_update" --account "$account" --verify "$dmg" "$signature"
mkdir -p "$output"
mv "$dmg" "$feed" "$output/"
echo "Verified $output/CodeShot.dmg and $output/appcast.xml"
