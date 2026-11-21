// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Self-contained Trace Specification v1 conformance harness for the Swift SDK.
// A nested package with a RELATIVE path dependency on DProvenanceKit (the parent dir),
// so it runs anywhere the repo is checked out:  swift run --package-path ConformanceHarness
//
// SwiftPM names a path dependency after its DIRECTORY, not its manifest's `name:`, so a
// hard-coded `package: "DProvenanceKit"` broke in any clone not literally named
// DProvenanceKit (`git clone … dpk`, CI checkouts into custom paths, worktrees). The
// identity is derived from the parent directory's name instead.
let parentPackageIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // ConformanceHarness/
    .deletingLastPathComponent()   // repo root
    .lastPathComponent

let package = Package(
    name: "ConformanceHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "ConformanceHarness",
            dependencies: [.product(name: "DProvenanceKit", package: parentPackageIdentity)]
        )
    ]
)
