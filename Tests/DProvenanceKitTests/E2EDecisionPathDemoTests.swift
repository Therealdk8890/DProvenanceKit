import XCTest
import E2EDecisionPathDemoLib

/// Locks the e2e decision-path demo story so it cannot silently rot.
///
/// Asserts the same CI markers as the Python twin
/// (`examples/e2e_decision_path` in DProvenanceKitPython): gate fails HIGH on the
/// regressed candidate, and baseline attestation verifies.
final class E2EDecisionPathDemoTests: XCTestCase {
    func testE2EDecisionPathDemoGateFailAndAttestOK() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpk-e2e-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        var lines: [String] = []
        let code = await E2EDecisionPathDemoRunner.run(
            options: .init(outputDirectory: outDir, keep: true),
            log: { lines.append($0) }
        )
        let out = lines.joined(separator: "\n")

        XCTAssertEqual(code, 0, "demo story should exit 0; output:\n\(out)")
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerGateFail), out)
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerGateLevel), out)
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerAttestOK), out)
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerDemoOK), out)
        XCTAssertTrue(out.contains("claimVerified"), out)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("traces.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("baseline.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("baseline_attestation.json").path))
    }

    func testE2EDecisionPathDemoRunnerEntry() async {
        var lines: [String] = []
        let code = await E2EDecisionPathDemoRunner.run(
            options: .init(outputDirectory: nil, keep: false),
            log: { lines.append($0) }
        )
        let out = lines.joined(separator: "\n")
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerGateFail), out)
        XCTAssertTrue(out.contains(E2EDecisionPathDemoRunner.markerAttestOK), out)
    }
}
