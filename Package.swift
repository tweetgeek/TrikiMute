// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrikiMute",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TrikiMuteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TrikiMute",
            dependencies: ["TrikiMuteCore"],
            exclude: ["Info.plist", "TrikiMute.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrikiMuteCoreTests",
            dependencies: ["TrikiMuteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
