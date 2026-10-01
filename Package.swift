// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AudioMixer", platforms: [.macOS(.v15)], targets: [
    .executableTarget(name: "AudioMixer", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])
])
