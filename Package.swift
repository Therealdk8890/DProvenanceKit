// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DProvenanceKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DProvenanceKit",
            targets: ["DProvenanceKit"]
        ),
        .executable(
            name: "DProvenanceUI",
            targets: ["DProvenanceUI"]
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DProvenanceKit"
        ),
        .executableTarget(
            name: "DProvenanceUI",
            dependencies: ["DProvenanceKit"]
        ),
        .testTarget(
            name: "DProvenanceKitTests",
            dependencies: ["DProvenanceKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
