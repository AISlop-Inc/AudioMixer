// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioMixer",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AudioMixer",
            path: "Sources",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
