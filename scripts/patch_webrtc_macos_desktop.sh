#!/bin/zsh
#
# patch_webrtc_macos_desktop.sh
#
# Prepares a patched copy of the WebRTC macOS slice that has a complete set of
# headers (taken from the maccatalyst slice which ships them).
#
# Why: stasel/WebRTC 146 ships a real macOS (x86_64+arm64) binary with the
# symbols we need (RTCPeerConnection, RTCPeerConnectionFactory, audio tracks etc),
# BUT the native macos-x86_64_arm64 slice only contains a stub WebRTC.h that
# #imports dozens of headers that don't exist in that slice.
#
# This causes Clang module scanning to fail for the "Construct Desktop" target
# with "RTCAudioSource.h file not found".
#
# The maccatalyst slice has the full public headers. The API surface used for
# audio calls is the same, and the mac binary contains the required ObjC classes.
#
# Usage:
#   - Run this script manually before building Desktop, OR
#   - Add it as a "Run Script" build phase (early) in the "Construct Desktop"
#     target. It will place a patched framework under:
#       ${TARGET_TEMP_DIR}/WebRTC-Desktop-Patched/WebRTC.framework
#
#   Then add the following to the "Construct Desktop" target's Build Settings
#   (Debug/Beta/Release), at the front of FRAMEWORK_SEARCH_PATHS:
#
#       $(TARGET_TEMP_DIR)/WebRTC-Desktop-Patched
#
#   This makes `import WebRTC` resolve the patched copy (good headers) while
#   the actual dylib that gets linked/embedded can still come from the SPM
#   product (or you can also embed the patched one).
#
# The script is idempotent and safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Xcode sets these during build. When run manually we fall back.
TARGET_TEMP_DIR="${TARGET_TEMP_DIR:-${SRCROOT}/build/DesktopWebRTCPatched}"
BUILD_DIR="${BUILD_DIR:-${SRCROOT}/build}"

PATCH_ROOT="${TARGET_TEMP_DIR}/WebRTC-Desktop-Patched"
PATCHED_FW="${PATCH_ROOT}/WebRTC.framework"

# Locate the resolved xcframework from SPM artifacts.
# The path pattern inside DerivedData is stable for this project.
# We walk upwards from common locations.
ARTIFACT_CANDIDATES=(
    "${BUILD_DIR%Build/*}SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
    "${SRCROOT}/build/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
    "${HOME}/Library/Developer/Xcode/DerivedData/ConstructMessenger-*/SourcePackages/artifacts/webrtc/WebRTC/WebRTC.xcframework"
)

ARTIFACT=""
for cand in "${ARTIFACT_CANDIDATES[@]}"; do
    # expand globs
    for expanded in $(eval echo "$cand" 2>/dev/null || true); do
        if [[ -d "$expanded" && -f "$expanded/Info.plist" ]]; then
            ARTIFACT="$expanded"
            break 2
        fi
    done
done

if [[ -z "$ARTIFACT" ]]; then
    # Last resort: search
    ARTIFACT=$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*webrtc/WebRTC/WebRTC.xcframework' -type d 2>/dev/null | head -1 || true)
fi

if [[ -z "$ARTIFACT" || ! -d "$ARTIFACT" ]]; then
    echo "error: Could not locate WebRTC.xcframework in SPM artifacts." >&2
    echo "       Build the project at least once with the iOS target first, or run:" >&2
    echo "       xcodebuild -scheme \"Construct Desktop\" -destination 'platform=macOS' build" >&2
    echo "       (the package must be resolved)." >&2
    exit 1
fi

MAC_SLICE="${ARTIFACT}/macos-x86_64_arm64/WebRTC.framework"
MACCAT_HEADERS="${ARTIFACT}/ios-x86_64_arm64-maccatalyst/WebRTC.framework/Headers"

if [[ ! -d "$MAC_SLICE" ]]; then
    echo "error: macOS slice not found at $MAC_SLICE" >&2
    exit 1
fi
if [[ ! -d "$MACCAT_HEADERS" ]]; then
    echo "error: maccatalyst headers not found at $MACCAT_HEADERS" >&2
    exit 1
fi

echo "Patching WebRTC for macOS Desktop..."
echo "  mac slice:    $MAC_SLICE"
echo "  full headers: $MACCAT_HEADERS"
echo "  -> $PATCHED_FW"

# Clean previous patch completely to avoid symlink/permission issues on re-run
rm -rf "$PATCH_ROOT"

# Replicate the macOS framework (binary + bundle structure) first.
# ditto is preferred on macOS for frameworks; fall back to cp -a.
mkdir -p "$(dirname "$PATCHED_FW")"
if command -v ditto >/dev/null 2>&1; then
    ditto "$MAC_SLICE" "$PATCHED_FW"
else
    cp -a "$MAC_SLICE" "$PATCHED_FW"
fi

# Build a curated minimal header set for native macOS Desktop.
# Only the pieces needed for audio-only calls (peer connection, ICE, RTP, audio tracks).
# This excludes RTCEAGLVideoView, camera capturers and other UIKit-pulling headers
# that the full catalyst set contains.
rm -rf "$PATCHED_FW/Headers"
mkdir -p "$PATCHED_FW/Headers" "$PATCHED_FW/Modules"

SAFE_HEADERS=(
    RTCAudioSource.h RTCAudioTrack.h
    RTCCertificate.h RTCConfiguration.h RTCCryptoOptions.h
    RTCDataChannel.h RTCDataChannelConfiguration.h
    RTCDtmfSender.h RTCFieldTrials.h
    RTCIceCandidate.h RTCIceCandidateErrorEvent.h RTCIceServer.h
    RTCLegacyStatsReport.h
    RTCMediaConstraints.h RTCMediaSource.h RTCMediaStream.h RTCMediaStreamTrack.h
    RTCMetrics.h RTCMetricsSampleInfo.h
    RTCPeerConnection.h RTCPeerConnectionFactory.h RTCPeerConnectionFactoryOptions.h
    RTCRtcpParameters.h
    RTCRtpCapabilities.h RTCRtpCodecCapability.h RTCRtpCodecParameters.h
    RTCRtpEncodingParameters.h RTCRtpHeaderExtension.h RTCRtpHeaderExtensionCapability.h
    RTCRtpParameters.h RTCRtpReceiver.h RTCRtpSender.h RTCRtpSource.h RTCRtpTransceiver.h
    RTCSessionDescription.h
    RTCSSLAdapter.h RTCSSLCertificateVerifier.h
    RTCStatisticsReport.h RTCTracing.h
)

for h in "${SAFE_HEADERS[@]}"; do
    [[ -f "$MACCAT_HEADERS/$h" ]] && cp -f "$MACCAT_HEADERS/$h" "$PATCHED_FW/Headers/$h"
done

# Hand-written minimal umbrella containing only safe imports.
cat > "$PATCHED_FW/Headers/WebRTC.h" << 'UMBRELLA'
/*
 *  Minimal WebRTC umbrella for native macOS (audio calls only).
 *  Avoids all video/UI headers that transitively require UIKit.
 */
#import <WebRTC/RTCAudioSource.h>
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCCertificate.h>
#import <WebRTC/RTCConfiguration.h>
#import <WebRTC/RTCCryptoOptions.h>
#import <WebRTC/RTCDataChannel.h>
#import <WebRTC/RTCDataChannelConfiguration.h>
#import <WebRTC/RTCDtmfSender.h>
#import <WebRTC/RTCFieldTrials.h>
#import <WebRTC/RTCIceCandidate.h>
#import <WebRTC/RTCIceCandidateErrorEvent.h>
#import <WebRTC/RTCIceServer.h>
#import <WebRTC/RTCLegacyStatsReport.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaSource.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCMediaStreamTrack.h>
#import <WebRTC/RTCMetrics.h>
#import <WebRTC/RTCMetricsSampleInfo.h>
#import <WebRTC/RTCPeerConnection.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCPeerConnectionFactoryOptions.h>
#import <WebRTC/RTCRtcpParameters.h>
#import <WebRTC/RTCRtpCapabilities.h>
#import <WebRTC/RTCRtpCodecCapability.h>
#import <WebRTC/RTCRtpCodecParameters.h>
#import <WebRTC/RTCRtpEncodingParameters.h>
#import <WebRTC/RTCRtpHeaderExtension.h>
#import <WebRTC/RTCRtpHeaderExtensionCapability.h>
#import <WebRTC/RTCRtpParameters.h>
#import <WebRTC/RTCRtpReceiver.h>
#import <WebRTC/RTCRtpSender.h>
#import <WebRTC/RTCRtpSource.h>
#import <WebRTC/RTCRtpTransceiver.h>
#import <WebRTC/RTCSessionDescription.h>
#import <WebRTC/RTCSSLAdapter.h>
#import <WebRTC/RTCSSLCertificateVerifier.h>
#import <WebRTC/RTCStatisticsReport.h>
#import <WebRTC/RTCTracing.h>
UMBRELLA

# Invalidate any cached module info
touch "$PATCHED_FW/WebRTC" "$PATCHED_FW/Headers/WebRTC.h" 2>/dev/null || true

# Stage a copy into the app bundle's Frameworks (so it gets embedded and is available at runtime).
# This replaces what the SPM WebRTC product used to do for this target.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${FRAMEWORKS_FOLDER_PATH:-}" ]]; then
    DEST_FW_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
    mkdir -p "$DEST_FW_DIR"
    rm -rf "$DEST_FW_DIR/WebRTC.framework"
    if command -v ditto >/dev/null 2>&1; then
        ditto "$PATCHED_FW" "$DEST_FW_DIR/WebRTC.framework"
    else
        cp -RP "$PATCHED_FW" "$DEST_FW_DIR/WebRTC.framework"
    fi
    echo "   Also staged to $DEST_FW_DIR/WebRTC.framework for embedding."
fi

# Nuclear option for the clang scanner: any WebRTC.framework that Xcode/SPM staged into
# Products or build dirs for *this* target gets the full headers overlaid in place.
# This catches the exact path the error mentions (/.../Products/Debug/WebRTC.framework).
for staged in \
    "${TARGET_BUILD_DIR}/WebRTC.framework" \
    "${BUILT_PRODUCTS_DIR}/WebRTC.framework" \
    "${TARGET_TEMP_DIR}/../Products/Debug/WebRTC.framework" \
    "${BUILD_DIR}/Products/Debug/WebRTC.framework" \
    ; do
    if [[ -d "$staged" && -f "$staged/Headers/WebRTC.h" ]]; then
        echo "Overlaying full headers into staged $staged ..."
        cp -f "$MACCAT_HEADERS"/*.h "$staged/Headers/" 2>/dev/null || true
        if [[ -f "$MACCAT_HEADERS/WebRTC.h" ]]; then
            cp -f "$MACCAT_HEADERS/WebRTC.h" "$staged/Headers/WebRTC.h"
        fi
        # Strip UIKit from the staged copy too
        find "$staged/Headers" -name '*.h' -exec sed -i '' 's|#import <UIKit/UIKit.h>||g' {} + 2>/dev/null || true
        find "$staged/Headers" -name '*.h' -exec sed -i '' 's|#import <UIKit/.*>||g' {} + 2>/dev/null || true
    fi
done

echo "✅ Patched WebRTC.framework ready."
echo "   Headers count: $(ls "$PATCHED_FW/Headers" | wc -l | tr -d ' ')"
echo ""
echo "The Run Script phase + FRAMEWORK_SEARCH_PATHS should now let 'import WebRTC' succeed."
echo "Tip: Clean Build Folder (Shift-Cmd-K) or nuke DerivedData on first try after this change."
