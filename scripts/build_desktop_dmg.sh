#!/usr/bin/env bash
#
# build_desktop_dmg.sh — Construct Desktop as a signed DMG for Macs other than this one.
#
#   ./scripts/build_desktop_dmg.sh                archive, export, DMG — signed, not notarized
#   ./scripts/build_desktop_dmg.sh --notarize     plus notarization and stapling
#   ./scripts/build_desktop_dmg.sh --no-build     reuse the last archive
#   ./scripts/build_desktop_dmg.sh --release      Release instead of Beta
#   ./scripts/build_desktop_dmg.sh --arch arm64   one architecture (arm64 | x86_64 | all, default all)
#   ./scripts/build_desktop_dmg.sh --notarize --publish
#                                                 plus a GitHub release and the update feeds
#
# Beta by default — what TestFlight gets on iOS: Release plus DEBUG
# (Config/Beta.xcconfig), against the production server. DEBUG is what offers
# linking another device at onboarding (DeviceLinkOfferPolicy) and the debug
# surfaces; a Release DMG has neither, so a tester can only restore from a phrase.
#
# History after linking follows the link (DeviceLinkHistorySyncPolicy): a Beta DMG
# offers both, a Release one neither. Both devices ask, so the phone needs a Debug or
# Beta build too (docs/HISTORY_STAND.md).
#
# Result: build/desktop/Construct Desktop <version> (<build>) <configuration> <arch>.dmg
#
# One DMG per architecture, never a universal one: a universal app is twice the size for
# every Mac. Each archive is built for its ARCHS only, and every fat Mach-O it embeds
# (WebRTC, Sparkle) is thinned to that architecture before export signs it.
#
# Signing: Developer ID Application from the keychain, picked by SHA-1 — the same
# certificate often sits in two keychains, and codesign by name then answers
# "ambiguous". Override with CODESIGN_IDENTITY.
#
# Notarization reads a notarytool keychain profile (NOTARY_PROFILE, default
# construct-notary). The profile belongs to an Apple ID and team, not to an app, so
# one saved for another project of the same team works too. To save one:
#
#   xcrun notarytool store-credentials construct-notary \
#       --apple-id <Apple ID> --team-id <team> --password <app-specific password>
#
# Architectures: the macOS slices of ConstructCore and ConstructTransport are arm64
# unless built with --dist (./build_crypto_lib.sh --all --dist,
# ./build_transport_lib.sh --all --dist); an x86_64 DMG needs both.
#
# Updates (Sparkle, Beta only for now): --publish puts the DMGs in a pre-release
# desktop-v<version>-<build> of konstruct-msg/construct-apple and adds them to the feeds,
# appcast-<arch>.xml, assets of the fixed release desktop-beta-feed
# (DesktopUpdateFeed.swift reads them). Each enclosure carries the EdDSA signature
# sign_update makes with the key in the login keychain, account konstruct-desktop
# (Sparkle's generate_keys); the app installs nothing that does not verify against
# SUPublicEDKey in Construct Desktop/Info.plist. Lose that key and no installed copy
# can be updated again: keep an export of it (generate_keys --account
# konstruct-desktop -x <file>) somewhere safe. HEAD must be pushed.
#
# Versions: Desktop keeps its own MARKETING_VERSION / CURRENT_PROJECT_VERSION on the
# target (scripts/check_build_versions.sh exempts it); raise the build number before
# handing out a second DMG, or two of them cannot be told apart.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCHEME="Construct Desktop"
PRODUCT="Construct Desktop"
OUT="build/desktop"
STAGING="$OUT/dmg-staging"
REPO="konstruct-msg/construct-apple"
FEED_TAG="desktop-beta-feed"
SPARKLE_ACCOUNT="konstruct-desktop"

CONFIGURATION="Beta"
BUILD=1
NOTARIZE=0
PUBLISH=0
ARCH_ARG="all"
IDENTITY="${CODESIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-construct-notary}"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --notarize) NOTARIZE=1 ;;
        --release) CONFIGURATION="Release" ;;
        --arch) ARCH_ARG="$2"; shift ;;
        --publish) PUBLISH=1 ;;
        --keychain-profile) PROFILE="$2"; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ "$PUBLISH" -eq 1 ]; then
    [ "$NOTARIZE" -eq 1 ] || { echo "--publish needs --notarize: Gatekeeper refuses an unnotarized update" >&2; exit 2; }
    [ "$CONFIGURATION" = "Beta" ] || { echo "--publish is Beta only: Release has no feed yet" >&2; exit 2; }
    [ -n "$(git branch -r --contains HEAD 2>/dev/null)" ] || { echo "--publish: HEAD is not pushed; the release tag points at it" >&2; exit 2; }
fi

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
case "$ARCH_ARG" in
    all) ARCH_LIST=(arm64 x86_64) ;;
    arm64|x86_64) ARCH_LIST=("$ARCH_ARG") ;;
    *) echo "--arch: arm64, x86_64 or all" >&2; exit 2 ;;
esac
for arch in "${ARCH_LIST[@]}"; do
    for pair in "ConstructCore:$CORE_ARCHS:crypto" "ConstructTransport:$TRANSPORT_ARCHS:transport"; do
        IFS=: read -r name archs script <<<"$pair"
        [[ " $archs " == *" $arch "* ]] || {
            echo "$name has no $arch macOS slice — ./build_${script}_lib.sh --all --dist (or --arch arm64)" >&2; exit 1; }
    done
done

# Every fat Mach-O in the bundle keeps only $2. Export signs the bundle afterwards.
thin_app() {
    local app="$1" arch="$2" f archs
    while IFS= read -r -d '' f; do
        archs="$(lipo -archs "$f" 2>/dev/null)" || continue
        [[ "$archs" == *" "* ]] || continue
        lipo -thin "$arch" "$f" -output "$f.thin" && mv "$f.thin" "$f"
    done < <(find "$app" -type f -print0)
}

# --- per architecture: archive, thin, export, DMG, notarize -----------------

TEAM_ID="$(xcodebuild -project ConstructMessenger.xcodeproj -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
           | awk -F' = ' '/^ *DEVELOPMENT_TEAM =/{print $2; exit}')"
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
mkdir -p "$OUT"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

DMGS=()
for ARCH in "${ARCH_LIST[@]}"; do
    ARCHIVE="$OUT/ConstructDesktop-$ARCH.xcarchive"
    EXPORT="$OUT/export-$ARCH"

    if [ "$BUILD" -eq 1 ]; then
        say "archive ($CONFIGURATION, $ARCH)"
        rm -rf "${ARCHIVE:?}"
        xcodebuild archive -quiet \
            -project ConstructMessenger.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" \
            -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
            ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO
        thin_app "$ARCHIVE/Products/Applications/$PRODUCT.app" "$ARCH"
    fi
    [ -d "$ARCHIVE" ] || { echo "no archive at $ARCHIVE — run without --no-build" >&2; exit 1; }

    say "export (Developer ID, $ARCH)"
    rm -rf "${EXPORT:?}"
    xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
        -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates

    APP="$EXPORT/$PRODUCT.app"
    codesign --verify --deep --strict "$APP"
    [ "$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")" = "$ARCH" ] || { echo "$APP is not $ARCH-only" >&2; exit 1; }
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
    MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
    DMG="$OUT/$PRODUCT $VERSION ($BUILD_NUMBER) $CONFIGURATION $ARCH.dmg"

    # The app inside is not stapled on its own. Notarizing the DMG registers the app's
    # hash as well, so Gatekeeper finds its ticket online at the first launch; a Mac that
    # is offline at that moment refuses it. Stapling the app too costs a second submission.
    say "disk image ($ARCH)"
    rm -rf "${STAGING:?}" && mkdir -p "$STAGING"
    ditto "$APP" "$STAGING/$PRODUCT.app"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$PRODUCT" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    rm -rf "${STAGING:?}"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    if [ "$NOTARIZE" -eq 1 ]; then
        say "notarization ($ARCH, profile $PROFILE)"
        if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
            echo "notarization failed; if the profile is missing: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id $TEAM_ID" >&2
            exit 1
        fi
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    fi
    DMGS+=("$ARCH|$DMG")
done

# --- publish: release + feeds -------------------------------------------------

if [ "$PUBLISH" -eq 1 ]; then
    # find exits non-zero on any unreadable folder in DerivedData; under pipefail that ended
    # the script here, silently, after the release was made and before the feeds (0.3.21).
    SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$( { find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null || true; } | head -1)}"
    [ -x "$SIGN_UPDATE" ] || { echo "sign_update not found; set SPARKLE_SIGN_UPDATE" >&2; exit 1; }

    TAG="desktop-v$VERSION-$BUILD_NUMBER"
    PUB="$OUT/publish"
    rm -rf "${PUB:?}" && mkdir -p "$PUB"
    ASSETS=()
    for entry in "${DMGS[@]}"; do
        arch="${entry%%|*}"; dmg="${entry#*|}"
        # GitHub rewrites spaces and parentheses in asset names; the feed needs the exact name.
        asset="Konstruct-Desktop-$VERSION-$BUILD_NUMBER-beta-$arch.dmg"
        cp "$dmg" "$PUB/$asset"
        ASSETS+=("$PUB/$asset")
    done

    say "release $TAG"
    # A second --publish of the same build (one that stopped half-way) replaces the assets.
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$TAG" --repo "$REPO" --clobber "${ASSETS[@]}"
    else
        gh release create "$TAG" --repo "$REPO" --prerelease --target "$(git rev-parse HEAD)" \
            --title "Konstruct Desktop $VERSION ($BUILD_NUMBER) beta" \
            --notes "Konstruct Desktop beta, one DMG per architecture: arm64 for Apple silicon, x86_64 for Intel. Installed copies update themselves." \
            "${ASSETS[@]}"
    fi

    gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1 || \
        gh release create "$FEED_TAG" --repo "$REPO" --prerelease --target "$(git rev-parse HEAD)" \
            --title "Konstruct Desktop beta update feeds" \
            --notes "Update feeds read by Konstruct Desktop (appcast-<arch>.xml). Replaced by scripts/build_desktop_dmg.sh --publish on every build; do not delete."

    for asset in "${ASSETS[@]}"; do
        arch="${asset##*-beta-}"; arch="${arch%.dmg}"
        feed="$PUB/appcast-$arch.xml"
        gh release download "$FEED_TAG" --repo "$REPO" -p "appcast-$arch.xml" -O "$feed" 2>/dev/null || rm -f "$feed"
        signature="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$asset")"
        url="https://github.com/$REPO/releases/download/$TAG/$(basename "$asset")"
        python3 -I - "$feed" "$VERSION" "$BUILD_NUMBER" "$MIN_SYSTEM" "$url" "$signature" <<'PY'
import sys, html, email.utils
feed, version, build, min_system, url, signature = sys.argv[1:]
head = ('<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        '<channel>\n<title>Konstruct Desktop beta</title>\n')
tail = '</channel>\n</rss>\n'
try:
    old = open(feed, encoding="utf-8").read()
    items = old.split("<channel>", 1)[1].rsplit("</channel>", 1)[0]
    items = items[items.find("<item>"):] if "<item>" in items else ""
except FileNotFoundError:
    items = ""
# Newest first; a rebuilt number replaces its old entry; ten entries are enough to update from.
kept = [i for i in items.split("</item>") if "<item>" in i and f"<sparkle:version>{build}</sparkle:version>" not in i]
kept = [i.strip() + "\n</item>\n" for i in kept][:9]
item = (f'<item>\n<title>{html.escape(version)} ({html.escape(build)})</title>\n'
        f'<pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>\n'
        f'<sparkle:version>{html.escape(build)}</sparkle:version>\n'
        f'<sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>\n'
        f'<sparkle:minimumSystemVersion>{html.escape(min_system)}</sparkle:minimumSystemVersion>\n'
        f'<enclosure url="{html.escape(url)}" type="application/octet-stream" {signature.strip()}/>\n'
        '</item>\n')
open(feed, "w", encoding="utf-8").write(head + item + "".join(kept) + tail)
PY
        gh release upload "$FEED_TAG" --repo "$REPO" --clobber "$feed"
        echo "  feed appcast-$arch.xml → $TAG"
    done
fi

say "done"
for entry in "${DMGS[@]}"; do echo "  ${entry#*|} ($CONFIGURATION)"; done
[ "$NOTARIZE" -eq 1 ] || echo "  not notarized — Gatekeeper on another Mac will refuse it; rerun with --notarize"
