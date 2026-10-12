#!/usr/bin/env bash
#
# build_desktop_dmg.sh — Construct Desktop as a signed DMG for Macs other than this one.
#
#   ./scripts/build_desktop_dmg.sh                archive, export, DMG — signed, not notarized
#   ./scripts/build_desktop_dmg.sh --notarize     plus notarization and stapling
#   ./scripts/build_desktop_dmg.sh --no-build     reuse the last archive
#   ./scripts/build_desktop_dmg.sh --release      Release instead of Beta
#   ./scripts/build_desktop_dmg.sh --history-stand  plus -DHISTORY_STAND
#
# Beta by default — what TestFlight gets on iOS: Release plus DEBUG
# (Config/Beta.xcconfig), against the production server. DEBUG is what offers
# linking another device at onboarding (DeviceLinkOfferPolicy) and the debug
# surfaces; a Release DMG has neither, so a tester can only restore from a phrase.
#
# History after linking is a second gate: DeviceLinkHistorySyncPolicy offers it only
# in a build with -DHISTORY_STAND, which no configuration defines (docs/HISTORY_STAND.md).
# Both devices check it — the phone that sends and the Mac that receives — so a
# --history-stand DMG transfers history only with a phone built with the flag too.
#
# Result: build/desktop/Construct Desktop <version> (<build>).dmg
#
# Signing: Developer ID Application from the keychain, picked by SHA-1 — the same
# certificate often sits in two keychains, and codesign by name then answers
# "ambiguous". Override with CODESIGN_IDENTITY.
#
# Notarization reads a notarytool keychain profile (NOTARY_PROFILE, default
# konstruct-notary). The profile belongs to an Apple ID and team, not to an app, so
# one saved for another project of the same team works too. To save one:
#
#   xcrun notarytool store-credentials konstruct-notary \
#       --apple-id <Apple ID> --team-id <team> --password <app-specific password>
#
# Architectures follow the xcframeworks: the macOS slices of ConstructCore and
# ConstructTransport are arm64 unless built with --dist, and an x86_64 link against
# an arm64-only slice fails. The DMG is universal only when both slices are.
#
# Versions: Desktop keeps its own MARKETING_VERSION / CURRENT_PROJECT_VERSION on the
# target (scripts/check_build_versions.sh exempts it); raise the build number before
# handing out a second DMG, or two of them cannot be told apart.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCHEME="Construct Desktop"
PRODUCT="Construct Desktop"
OUT="build/desktop"
ARCHIVE="$OUT/ConstructDesktop.xcarchive"
EXPORT="$OUT/export"
STAGING="$OUT/dmg-staging"

CONFIGURATION="Beta"
HISTORY_STAND=0
BUILD=1
NOTARIZE=0
IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-konstruct-notary}"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --notarize) NOTARIZE=1 ;;
        --release) CONFIGURATION="Release" ;;
        --history-stand) HISTORY_STAND=1 ;;
        --keychain-profile) PROFILE="$2"; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
                | awk '/Developer ID Application/{print $2; exit}')"
fi
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }

# --- architectures ----------------------------------------------------------

slice_archs() {
    local lib
    lib="$(find "$1.xcframework" -path '*macos-*' -name '*.a' | head -1)"
    [ -n "$lib" ] || { echo "$1.xcframework has no macOS slice — ./build_${2}_lib.sh --all" >&2; exit 1; }
    lipo -archs "$lib"
}
CORE_ARCHS="$(slice_archs ConstructCore crypto)"
TRANSPORT_ARCHS="$(slice_archs ConstructTransport transport)"
ARCHS="arm64"
if [[ " $CORE_ARCHS " == *" x86_64 "* && " $TRANSPORT_ARCHS " == *" x86_64 "* ]]; then
    ARCHS="arm64 x86_64"
fi

# --- archive and export -----------------------------------------------------

EXTRA=()
FLAVOUR="$CONFIGURATION"
if [ "$HISTORY_STAND" -eq 1 ]; then
    EXTRA=(OTHER_SWIFT_FLAGS='$(inherited) -DHISTORY_STAND')
    FLAVOUR="$CONFIGURATION history-stand"
fi

if [ "$BUILD" -eq 1 ]; then
    say "archive ($FLAVOUR, $ARCHS)"
    rm -rf "${ARCHIVE:?}"
    xcodebuild archive -quiet \
        -project ConstructMessenger.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
        ARCHS="$ARCHS" ${EXTRA[@]+"${EXTRA[@]}"}
fi
[ -d "$ARCHIVE" ] || { echo "no archive at $ARCHIVE — run without --no-build" >&2; exit 1; }

TEAM_ID="$(xcodebuild -project ConstructMessenger.xcodeproj -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
           | awk -F' = ' '/^ *DEVELOPMENT_TEAM =/{print $2; exit}')"

say "export (Developer ID)"
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
rm -rf "${EXPORT:?}"
xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates

APP="$EXPORT/$PRODUCT.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT/$PRODUCT $VERSION ($BUILD_NUMBER) $FLAVOUR.dmg"

# --- DMG --------------------------------------------------------------------

# The app inside is not stapled on its own. Notarizing the DMG registers the app's
# hash as well, so Gatekeeper finds its ticket online at the first launch; a Mac that
# is offline at that moment refuses it. Stapling the app too costs a second submission.
say "disk image"
rm -rf "${STAGING:?}" && mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$PRODUCT.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$PRODUCT" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "${STAGING:?}"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" -eq 1 ]; then
    say "notarization (profile $PROFILE)"
    if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
        echo "notarization failed; if the profile is missing: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id $TEAM_ID" >&2
        exit 1
    fi
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

say "done"
echo "  $DMG ($FLAVOUR, $ARCHS)"
[ "$NOTARIZE" -eq 1 ] || echo "  not notarized — Gatekeeper on another Mac will refuse it; rerun with --notarize"
