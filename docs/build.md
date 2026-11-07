# Build and distribution

The iOS app, share extension, and Mac target use the **iCloud.com.eminaydin.maccommand** container. Associate the same container with all three App IDs in the Apple Developer portal and refresh their signing profiles. Mac distribution requires a Developer ID profile with CloudKit entitlements.

For your own fork, use App IDs and a CloudKit container registered to your Apple Developer team. The iOS app and share extension must also share the same App Group identifier.

## CloudKit

[cloudkit/MacCommand.ckdb](../cloudkit/MacCommand.ckdb) defines the job record and indexes. Export the existing development schema and merge the MacCommandJob definition. Validate and import the development schema, then deploy the changes to **Production** in CloudKit Console. The app uses each user’s private database. The schema does not grant public database access. [Apple’s schema deployment guide](https://developer.apple.com/documentation/CloudKit/deploying-an-icloud-container-s-schema).

## Mac app

Run the commands from the repository root. Python and PyInstaller are required on the build machine. Prepare the bundled service with `build-mac.sh`, then create a distribution archive from the Xcode project with CloudKit enabled.

~~~sh
python3.14 -m venv .packaging
.packaging/bin/python -m pip install -r requirements.txt 'pyinstaller>=6.19,<7'
export MACCOMMAND_BUILD_PYTHON=.packaging/bin/python
export MACCOMMAND_SIGN_IDENTITY='Developer ID Application: …'
MACCOMMAND_PREVIEW=1 ./scripts/build-mac.sh
xcodebuild -project macos/MacCommandMac.xcodeproj -scheme MacCommand \
  -configuration Release -destination generic/platform=macOS \
  -archivePath build/macos/MacCommand.xcarchive DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates archive
~~~

Export the Mac archive using **Developer ID** in Xcode Organizer. Verify that the exported app’s iCloud environment entitlement is **Production**. Package a Developer ID signed DMG and submit it for Apple notarization. [Apple’s Developer ID documentation](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

~~~sh
export MACCOMMAND_NOTARY_PROFILE=MacCommand
./scripts/package-dmg.sh path/to/MacCommand.app MacCommand-3.1.1-English.dmg
~~~

## iPhone app

Create an archive and upload it for internal TestFlight testing.

~~~sh
export MACCOMMAND_IOS_TEAM='YOUR_TEAM_ID'
./scripts/archive-ios.sh
MACCOMMAND_IOS_DESTINATION=upload MACCOMMAND_IOS_REUSE_ARCHIVE=1 ./scripts/archive-ios.sh
~~~

Check Apple’s processing status. Complete the encryption export questions and beta information in App Store Connect. The initial distribution targets an internal testing group.

## Verification

~~~sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
./scripts/test.sh
.venv/bin/python scripts/test-relay-swift.py
~~~

The Mac helper tests verify the CloudKit packet format, file transfers, encrypted QR pairing, request expiry, and replay protection locally. Live CloudKit testing requires a signed app, the same Apple account on both devices, and a schema deployed to the target environment.

The iOS app can read the legacy pairing format for the 3.0 relay server. New Mac packages connect through CloudKit.
