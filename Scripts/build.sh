#!/bin/sh
# Builds Revoke signed with the team's Developer ID, notarises it, and staples the
# ticket, leaving the app at build/export/Revoke.app. install.sh and release.sh use it.
#
# The network filter is a system extension, whose entitlements come with provisioning
# profiles, so Xcode needs to be signed in to the team (DEVELOPMENT_TEAM in
# project.yml); -allowProvisioningUpdates lets it create them. Notarising uses the
# notarytool profile "notary" (see Release in the README).
set -eu
cd "$(dirname "$0")/.."
profile=notary

xcodegen generate --quiet
# Archive from scratch: Xcode leaves files removed from the project in the built app.
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
rm build/Revoke.zip
xcrun stapler staple -q "$app"
spctl --assess --type execute "$app"
