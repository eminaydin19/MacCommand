#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 path/to/MacCommand.app path/to/output.dmg" >&2
    exit 2
fi
app="$1"
dmg="$2"
stage=$(mktemp -d -t maccommand-dmg)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
codesign --verify --deep --strict "$app"
ditto "$app" "$stage/MacCommand.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname MacCommand -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
if [ -n "${MACCOMMAND_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$MACCOMMAND_SIGN_IDENTITY" "$dmg"
fi
if [ -n "${MACCOMMAND_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$MACCOMMAND_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi
hdiutil verify "$dmg"
