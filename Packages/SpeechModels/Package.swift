// swift-tools-version: 6.2
import PackageDescription

// FluidAudio with speech recognition only. Its default traits also bundle text-to-speech
// (whose word lists are derived from GPL-3.0 data), speaker diarization and a text
// normalization binary, none of which TapType uses. An Xcode project can't choose a
// package's traits, so this wrapper does.
let package = Package(
    name: "SpeechModels",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SpeechModels", targets: ["SpeechModels"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: [])
    ],
    targets: [
        .target(name: "SpeechModels", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
    ]
)
