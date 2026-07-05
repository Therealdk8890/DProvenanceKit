// swift-tools-version: 6.0
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
            targets: ["DProvenanceKit"
        .testTarget(
            name: "DProvenanceUITests",
            dependencies: ["DProvenanceUI"]
        ),
    ]
        ),
        .library(
            name: "DProvenanceUI",
            