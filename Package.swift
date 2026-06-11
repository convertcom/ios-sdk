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
