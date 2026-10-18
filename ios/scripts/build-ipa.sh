#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'iOS builds require macOS and Xcode. Use the Build iOS IPA GitHub workflow.' >&2
  exit 1
fi
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if (( ${sdk_version%%.*} < 26 )); then
  echo 'Select Xcode 26 or newer: the iOS native theme requires UIGlassEffect.' >&2
  exit 1
fi
python3 scripts/prepare-icons.py
python3 scripts/prepare-font.py
xcodegen generate --spec project.json
build_number="${LINCHE_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
xcodebuild -project LinChe.xcodeproj -scheme LinChe -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CURRENT_PROJECT_VERSION="$build_number" build

# Preserve App Groups for SideStore's entitlement discovery. These ad-hoc
# signatures contain no identity/certificate and must still be re-signed to install.
app_path="build/device/Build/Products/Release-iphoneos/LinChe.app"
codesign --force --sign - --generate-entitlement-der --entitlements Shared/Garden.entitlements "$app_path/PlugIns/GardenWidget.appex"
codesign --force --sign - --generate-entitlement-der --entitlements Shared/Garden.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"

# A fresh package directory prevents stale bundles entering a subsequent build.
package_dir="$(mktemp -d "$PWD/build/package.XXXXXX")"
mkdir -p "$package_dir/Payload"
ditto build/device/Build/Products/Release-iphoneos/LinChe.app "$package_dir/Payload/LinChe.app"
ipa_path="$PWD/build/LinChe-unsigned.ipa"
ditto -c -k --keepParent "$package_dir/Payload" "$ipa_path"
python3 scripts/verify-ipa.py "$ipa_path"
shasum -a 256 "$ipa_path" > build/LinChe-unsigned.ipa.sha256
echo "IPA: $ipa_path"
