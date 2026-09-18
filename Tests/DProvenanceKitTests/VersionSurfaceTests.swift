// Copyright 2026 Daniel Kissel
// Licensed under the Apache License, Version 2.0. See LICENSE for details.

import Foundation
import XCTest
@testable import DProvenanceKit

/// Guards README / docs version claims against `DProvenanceKitVersion.current`.
/// Prefer this over editing `.github/workflows/ci.yml` when the token lacks `workflow` scope.
final class VersionSurfaceTests: XCTestCase {
    func testReadmeInstallPinMatchesVersionConstant() throws {
        let root = try Self.repoRoot()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let version = DProvenanceKitVersion.current
        let pin = "from: \"\(version)\""
        XCTAssertTrue(
            readme.contains(pin),
            "README.md must pin SPM install with \(pin) (found Version.current=\(version))"
        )
    }

    func testVersionSurfaceDocMentionsCurrentSwiftVersion() throws {
        let root = try Self.repoRoot()
        let doc = try String(
            contentsOf: root.appendingPathComponent("docs/VERSION_SURFACE.md"),
            encoding: .utf8
        )
        let version = DProvenanceKitVersion.current
        XCTAssertTrue(
            doc.contains(version),
            "docs/VERSION_SURFACE.md must mention Swift \(version)"
        )
    }

    func testReadmeDoesNotClaimPythonAttestationNotYet() throws {
        let root = try Self.repoRoot()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        // Capability matrix row: attestation must not say Not yet for Python.
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let isAttestationRow = s.contains("Trace attestation") || s.contains("attestation (`DPK-")
            guard isAttestationRow else { continue }
            XCTAssertFalse(
                s.contains("Not yet"),
                "README attestation matrix still says Not yet for Python: \(s)"
            )
        }
    }

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // Tests/DProvenanceKitTests/ThisFile.swift -> repo root
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        let marker = url.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            XCTFail("could not locate Package.swift from \(#filePath)")
            throw NSError(domain: "VersionSurfaceTests", code: 1)
        }
        return url
    }
}
