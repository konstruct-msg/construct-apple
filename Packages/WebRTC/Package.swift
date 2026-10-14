// swift-tools-version:5.9
//
// webrtc-sdk's WebRTC build, under a manifest of our own.
//
// The binary is upstream's, pinned by checksum: SwiftPM refuses the zip if it is not the one
// hashed here. The manifest is ours because upstream's does not load. `webrtc-sdk/Specs` declares
// `swift-tools-version:5.9` and `.visionOS(.v26)`, which exists only from PackageDescription 6.2,
// on every tag including this one; and its tags (`150.7871.01`) are not semver, so a version rule
// cannot reach them either.
//
// Why this build and not `stasel/WebRTC`: the same line as Android (`io.github.webrtc-sdk:android`
// 150.7871.01), `+[RTCPeerConnectionFactory configureFieldTrials:]` to turn on post-quantum DTLS
// (`WebRTC-EnableDtlsPqc`), and the frame-encryption API for later. Module and class names are
// upstream's, without the `LK` prefix LiveKit's own package adds.
//
// To move to a newer build: change both the URL and the checksum
// (`swift package compute-checksum WebRTC.xcframework.zip`), and the Android version with it.

import PackageDescription

let package = Package(
    name: "WebRTC",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip",
            checksum: "03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa"
        ),
    ]
)
