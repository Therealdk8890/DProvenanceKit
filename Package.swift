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
            targets: ["DProvenanceKit"]
        ),
        .library(
            name: "DProvenanceUI",
            targets: ["DProvenanceUI"]
        ),
        .library(
            name: "DProvenanceFoundationModels",
            targets: ["DProvenanceFoundationModels"]
        ),
        .library(
            name: "DProvenanceOTel",
            targets: ["DProvenanceOTel"]
        ),
        .library(
            name: "DProvenanceFoundationModelsOTel",
            targets: ["DProvenanceFoundationModelsOTel"]
        ),
        .executable(
            name: "GenerateSample",
            targets: ["GenerateSample"]
        ),
        .executable(
            name: "DProvenanceKitCLI",
            targets: ["DProvenanceKitCLI"]
        ),
        .executable(
            name: "Quickstart",
            targets: ["Quickstart"]
        ),
        .executable(
            name: "FoundationModelsRegressionDemo",
            targets: ["FoundationModelsRegressionDemo"]
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DProvenanceKit"
        ),
        .target(
            name: "DProvenanceUI",
            dependencies: ["DProvenanceKit"]
        ),
        .target(
            name: "DProvenanceFoundationModels",
            dependencies: ["DProvenanceKit"]
        ),
        .target(
            name: "DProvenanceOTel",
            dependencies: ["DProvenanceKit"]
        ),
        // Bridge: makes FoundationModels traces carry gen_ai.* semantics when exported
        // via the OTel bridge. Depends on both so neither base module has to.
        .target(
            name: "DProvenanceFoundationModelsOTel",
            dependencies: ["DProvenanceFoundationModels", "DProvenanceOTel", "DProvenanceKit"]
        ),
        .executableTarget(
            name: "GenerateSample",
            dependencies: ["DProvenanceKit", "DProvenanceUI"],
            path: "scratch",
            sources: ["GenerateSample.swift"]
        ),
        .executableTarget(
            name: "DProvenanceKitCLI",
            dependencies: ["DProvenanceKit"]
        ),
        // Runnable end-to-end tour + compile-check of the documented public API.
        .executableTarget(
            name: "Quickstart",
            dependencies: ["DProvenanceKit"]
        ),
        // A polished, runnable Foundation Models regression scenario (post-hoc transcript
        // ingestion) that ends in a failing CI gate and a WebVisualizer export.
        .executableTarget(
            name: "FoundationModelsRegressionDemo",
            dependencies: ["DProvenanceKit", "DProvenanceFoundationModels"]
        ),
        .testTarget(
            name: "DProvenanceKitTests",
            dependencies: ["DProvenanceKit", "DProvenanceUI"]
        ),
        .testTarget(
            name: "DProvenanceUITests",
            dependencies: ["DProvenanceUI"]
        ),
        .testTarget(
            name: "DProvenanceFoundationModelsTests",
            dependencies: ["DProvenanceFoundationModels", "DProvenanceKit"]
        ),
        .testTarget(
            name: "DProvenanceOTelTests",
            dependencies: ["DProvenanceOTel", "DProvenanceKit"]
        ),
        .testTarget(
            name: "DProvenanceFoundationModelsOTelTests",
            dependencies: ["DProvenanceFoundationModelsOTel", "DProvenanceFoundationModels", "DProvenanceOTel", "DProvenanceKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
