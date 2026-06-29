// swift-tools-version: 5.10
import PackageDescription

// Self-contained Trace Specification v1 conformance harness for the Swift SDK.
// A nested package with a RELATIVE path dependency on DProvenanceKit (the parent dir),
// so it runs anywhere the repo is checked out:  swift run --package-path ConformanceHarness
let package = Package(
    name: "ConformanceHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "ConformanceHarness",
            dependencies: [.product(name: "DProvenanceKit", package: "DProvenanceKit")]
        )
    ]
)
