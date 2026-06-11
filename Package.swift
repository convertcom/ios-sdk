// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ConvertSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "ConvertSDK", targets: ["ConvertSDK"]),
    ],
    targets: [
        .target(
            name: "ConvertSDKCore",
            path: "Sources/ConvertSDKCore",
            // Generated/README.md documents the codegen command (AC2). It is a
            // non-Swift doc file inside a source directory; exclude it so SwiftPM
            // does not emit an "unhandled file" warning (AC7 — zero warnings).
            exclude: ["Generated/README.md"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConvertSDK",
            dependencies: ["ConvertSDKCore"],
            path: "Sources/ConvertSDK",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConvertSDKCoreTests",
            dependencies: ["ConvertSDKCore"],
            path: "Tests/ConvertSDKCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConvertSDKTests",
            dependencies: ["ConvertSDK"],
            path: "Tests/ConvertSDKTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
