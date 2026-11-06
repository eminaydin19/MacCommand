#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

python_bin=${MACCOMMAND_BUILD_PYTHON:-.venv/bin/python}
build_dir=${MACCOMMAND_MAC_BUILD_DIR:-build/macos}
relay=${MACCOMMAND_RELAY_URL:-}
sign_identity=${MACCOMMAND_SIGN_IDENTITY:--}
app="$build_dir/MacCommand.app"
if [ -z "$relay" ] && [ "${MACCOMMAND_PREVIEW:-0}" != 1 ]; then
    echo "Use the Mac Xcode target for a CloudKit release or set MACCOMMAND_PREVIEW=1 for a local preview." >&2
    exit 2
fi
case "$relay" in
    https://*) debug_flag= ;;
    http://127.0.0.1:*)
        [ "${MACCOMMAND_LOCAL_TEST:-0}" = 1 ] || exit 2
        debug_flag=-DDEBUG ;;
    '') debug_flag= ;;
    *) echo "The beta server must use HTTPS." >&2; exit 2 ;;
esac

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
plutil -replace MacCommandCloudEnabled -bool false "$app/Contents/Info.plist"
if [ -n "$relay" ]; then
    plutil -replace MacCommandRelayURL -string "$relay" "$app/Contents/Info.plist"
fi
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 -O $debug_flag \
    macos/MacCommandApp.swift ios/MacCommand/Core/CloudMailbox.swift \
    ios/MacCommand/Core/Models.swift ios/MacCommand/Core/RelayProtocol.swift -o "$app/Contents/MacOS/MacCommand"
mkdir -p "$build_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" ios/MacCommand/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
        --out "$build_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" ios/MacCommand/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
        --out "$build_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

if [ "$sign_identity" != "-" ]; then
    set -- --codesign-identity "$sign_identity"
else
    set --
fi
"$python_bin" -m PyInstaller --noconfirm --onefile --name MacCommandService --target-arch arm64 \
    --collect-submodules uvicorn --distpath "$build_dir/helper-dist" \
    --workpath "$build_dir/helper-build" --specpath "$build_dir" "$@" mac_app.py
install -m 755 "$build_dir/helper-dist/MacCommandService" "$app/Contents/Helpers/MacCommandService"
if [ "$sign_identity" != "-" ]; then
    codesign --force --timestamp --options runtime --sign "$sign_identity" "$app/Contents/Helpers/MacCommandService"
    codesign --force --timestamp --options runtime --sign "$sign_identity" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
"$app/Contents/Helpers/MacCommandService" --help >/dev/null
printf '%s\n' "$app"
