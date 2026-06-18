// swift-tools-version:5.10
// ISOLATED dev-tooling manifest — NEVER referenced by the root Package.swift.
// Exists only to run swift-openapi-generator (types-only) over the committed
// serving spec. swift-openapi-generator is a build-time generator: it never
// enters the consumer/runtime dependency graph (NFR16, NFR18, AC1).
//
// Pin: exact 1.12.2 — the generator's output format can change between minor
// versions and any drift would break the byte-identical PR-diff gate (AC8).
import PackageDescription

let package = Package(
    name: "GenerateConfigTypes",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-openapi-generator",
            exact: "1.12.2"
        )
    ],
    targets: [
        // Empty placeholder target. We invoke the generator's `swift-openapi-generator`
        // command-line executable directly from run.sh (via `swift run` against this
        // manifest's resolved dependency). No source of our own is compiled here.
        .executableTarget(
            name: "generate-config-types",
            path: "Sources/generate-config-types"
        )
    ]
)
