// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ConvertSwiftSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "ConvertSwiftSDK", targets: ["ConvertSwiftSDK"]),
    ],
    targets: [
        .target(
            name: "ConvertSwiftSDKCore",
            path: "Sources/ConvertSwiftSDKCore",
            // Generated/README.md documents the codegen command (AC2), and
            // Generated/discriminator-manifest.json is a build-time artifact
            // consumed by humans / the sentinel author (NOT a runtime resource).
            // Both are non-Swift files inside a source directory; exclude them so
            // SwiftPM does not emit an "unhandled file" warning (AC7 — zero warnings).
            exclude: [
                "Generated/README.md",
                "Generated/discriminator-manifest.json",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConvertSwiftSDK",
            dependencies: ["ConvertSwiftSDKCore"],
            path: "Sources/ConvertSwiftSDK",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConvertSwiftSDKCoreTests",
            dependencies: ["ConvertSwiftSDKCore"],
            path: "Tests/ConvertSwiftSDKCoreTests",
            // The Fixtures/ directory holds REAL CDN config captures consumed by
            // ConfigDecodeTests via `Bundle.module`. `.copy` of the whole directory
            // bundles its `.json` contents verbatim (no SwiftPM resource processing /
            // re-encoding) so the byte-level fidelity of the captures is preserved for
            // the round-trip assertions; the leftover `.gitkeep` rides along harmlessly.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConvertSwiftSDKTests",
            dependencies: ["ConvertSwiftSDK"],
            path: "Tests/ConvertSwiftSDKTests",
            // The Fixtures/ directory holds the committed REAL staging CDN config snapshot
            // (FS-Test-Proj — the AC5 staging coords) consumed by StagingIntegrationTests via
            // `Bundle.module`. `.copy` of the whole directory bundles its `.json` verbatim (no
            // SwiftPM resource processing / re-encoding) so the captured staging bytes load with
            // byte-level fidelity through the FR7 direct-data path — same `.copy` rationale as the
            // ConvertSwiftSDKCoreTests target's Fixtures above.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
