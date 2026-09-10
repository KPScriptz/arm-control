#!/usr/bin/env bash
#
# Archive + export a signed IPA for TestFlight.
#
# Bump CURRENT_PROJECT_VERSION in ArmControl.xcodeproj before EVERY upload — re-uploading the same
# version+build is rejected with "90189 Redundant Binary Upload".
#
# Manual signing on purpose: automatic signing needs a signed-in Apple ID in Xcode, and this Mac has
# none, so `-exportArchive` fails with "No Accounts". The profile below was created via the App
# Store Connect API and installed into ~/Library/MobileDevice/Provisioning Profiles.
set -euo pipefail
cd "$(dirname "$0")"

TEAM=ASN3GCJ3S9
BUNDLE=com.pivotxp.armcontrol
PROFILE="ArmControl AppStore CLI"

rm -rf build/ArmControl.xcarchive build/export
mkdir -p build

echo "==> Archiving"
xcodebuild -project ArmControl.xcodeproj -scheme ArmControl -configuration Release \
  -destination "generic/platform=iOS" -archivePath build/ArmControl.xcarchive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  DEVELOPMENT_TEAM="$TEAM" archive

cat > build/exportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>${TEAM}</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict><key>${BUNDLE}</key><string>${PROFILE}</string></dict>
    <key>uploadSymbols</key><true/>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting"
xcodebuild -exportArchive -archivePath build/ArmControl.xcarchive \
  -exportOptionsPlist build/exportOptions.plist -exportPath build/export

ls -la build/export/*.ipa
