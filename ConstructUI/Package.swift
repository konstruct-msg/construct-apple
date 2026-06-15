// swift-tools-version: 6.0
import PackageDescription

// ConstructUI — standalone design-system package.
//
// WHY THIS EXISTS: the main app target links WebRTC + WhisperKit (binary ObjC
// frameworks). Xcode Previews (XOJIT) crash at process launch with
// `_objc_fatal: Attempt to use unknown class` whenever those frameworks are
// loaded into the preview process — on any iOS runtime (18.6 and 26.2 both
// reproduce), independent of app code. Guards/compile-flags can't help because
// the frameworks stay linked.
//
// This package has ZERO dependency on the app / WebRTC / WhisperKit, so its
// preview process never loads them → previews work. Open this Package.swift
// directly in Xcode (File → Open…) and use the canvas on the showcase / any
// component here to iterate on design.
let package = Package(
    name: "ConstructUI",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ConstructUI", targets: ["ConstructUI"])
    ],
    targets: [
        .target(name: "ConstructUI")
    ]
)
