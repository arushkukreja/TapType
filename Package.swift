// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapTypeCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TapTypeCore", targets: ["TapTypeCore"])],
    targets: [
        .target(name: "TapTypeCore", path: "Shared", exclude: ["VoiceActivityAttributes.swift"]),
        .testTarget(name: "TapTypeCoreTests", dependencies: ["TapTypeCore"], path: "Tests/TapTypeCoreTests")
    ]
)
