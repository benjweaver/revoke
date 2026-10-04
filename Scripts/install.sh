#!/bin/sh
# Builds Revoke signed with the team's Developer ID, notarises it, and installs it in
# /Applications, replacing a running copy.
#
#   Scripts/install.sh
#
# The network filter is a system extension, which macOS only runs from
# /Applications, signed with a Developer ID and notarised. Its entitlements come with
# provisioning profiles that Xcode creates, so Xcode needs to be signed in to the
# team. Notarising uses the notarytool profile "notary"
# (`xcrun notarytool store-credentials notary`).
set -eu
cd "$(dirname "$0")/.."
profile=notary

xcodegen generate --quiet
rm -rf build/Revoke.xcarchive build/export build/Revoke.zip
xcodebuild archive -project Revoke.xcodeproj -scheme Revoke -configuration Release \
    -destination "generic/platform=macOS" -archivePath build/Revoke.xcarchive \
    -allowProvisioningUpdates -quiet
xcodebuild -exportArchive -archivePath build/Revoke.xcarchive -exportPath build/export \
    -exportOptionsPlist Scripts/ExportOptions.plist -allowProvisioningUpdates -quiet
app=build/export/Revoke.app

ditto -c -k --keepParent "$app" build/Revoke.zip
result=$(xcrun notarytool submit build/Revoke.zip --keychain-profile "$profile" --wait --output-format json)
if [ "$(printf '%s' "$result" | plutil -extract status raw -o - -)" != Accepted ]; then
    echo "notarisation failed: $result" >&2
    id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
    echo "details: xcrun notarytool log $id --keychain-profile $profile" >&2
    exit 1
fi
xcrun stapler staple -q "$app"
spctl --assess --type execute "$app"

pkill -x Revoke || true
# open fails with -600 if the old copy is still on its way out.
while pgrep -x Revoke >/dev/null; do sleep 0.2; done
rm -rf /Applications/Revoke.app
ditto "$app" /Applications/Revoke.app
open /Applications/Revoke.app
echo "Installed /Applications/Revoke.app"
