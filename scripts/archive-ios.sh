#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
team=${MACCOMMAND_IOS_TEAM:?set the Apple Developer team}
archive=${MACCOMMAND_IOS_ARCHIVE:-build/ios/MacCommand.xcarchive}
destination=${MACCOMMAND_IOS_DESTINATION:-export}
export_dir=${MACCOMMAND_IOS_EXPORT_DIR:-build/ios/export}
case "$destination" in export|upload) ;; *) exit 2 ;; esac

if [ "${MACCOMMAND_IOS_REUSE_ARCHIVE:-0}" != 1 ]; then
    xcodebuild -project ios/MacCommand.xcodeproj -scheme MacCommand -configuration Release \
        -destination generic/platform=iOS -archivePath "$archive" DEVELOPMENT_TEAM="$team" \
        -allowProvisioningUpdates archive
fi
options=$(mktemp -t maccommand-export)
trap 'rm -f "$options"' EXIT HUP INT TERM
plutil -create xml1 "$options"
plutil -insert method -string app-store-connect "$options"
plutil -insert destination -string "$destination" "$options"
plutil -insert teamID -string "$team" "$options"
plutil -insert signingStyle -string automatic "$options"
plutil -insert testFlightInternalTestingOnly -bool true "$options"
plutil -insert manageAppVersionAndBuildNumber -bool false "$options"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
    -exportPath "$export_dir" -allowProvisioningUpdates
