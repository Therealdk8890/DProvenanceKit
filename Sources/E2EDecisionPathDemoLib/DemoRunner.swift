import Foundation
import DProvenanceKit

/// One-shot decision-path demo: Instrument → Record → Baseline → Gate → Attest → Verify.
///
/// Real library APIs (not stubs):
///
/// 1. Instrument + record a clean baseline path into SQLite
/// 2. Pin it as a baseline artifact (attestable JSON + baseline.sqlite)
/// 3. Record a candidate that drops a CRITICAL step
/// 4. Align/gate fails (HIGH) on the regression
/// 5. Sign the baseline with software P-256 (`DPK-BINARY-V1`)
/// 6. Verify the attestation
///
/// Honest scope: tamper-evident record + CI gate + signed attestation of a
/// recorded path — not a claim that the decision was "sound".
///
/// Markers the CI test asserts on — keep stable (parity with the Python demo).
public enum E2EDecisionPathDemoRunner {
    public static let markerGateFail = "GATE_RESULT=FAIL"
    public static let markerGateLevel = "GATE_LEVEL=high"
    public static let markerAttestOK = "ATTEST_VERIFY=valid"
    public static let markerDemoOK = "DEMO_OK"

    public struct Options: Sendable {
        public var outputDirectory: URL?
        public var keep: Bool

        public init(outputDirectory: URL? = nil, keep: Bool = false) {
            self.outputDirectory = outputDirectory
            self.keep = keep
        }
    }

    /// Execute the full decision-path story. Returns 0 when the story holds.
    @discardableResult
    public static func run(
        options: Options = Options(),
        log: (String) -> Void = { print($0) }
    ) async -> Int {
        let cleanup: Bool
        let outDir: URL
        if let provided = options.outputDirectory {
            outDir = provided
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            cleanup = false
        } else {
            outDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dpk-e2e-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            cleanup = !options.keep
        }

        let tracesURL = outDir.appendingPathComponent("traces.sqlite")
        let baselineURL = outDir.appendingPathComponent("baseline.sqlite")
        let attestableURL = outDir.appendingPathComponent("baseline_attestable.json")
        let attestationURL = outDir.appendingPathComponent("baseline_attestation.json")

        log("DProvenanceKit e2e decision-path demo")
        log("Scope: tamper-evident record / CI gate / attest record — not 'prove sound reasoning'.")
        log("Artifacts: \(outDir.path)")

        defer {
            if cleanup {
                try? FileManager.default.removeItem(at: outDir)
            }
        }

        do {
            // ── 1. Instrument → Record baseline ──────────────────────────────
            banner(log, step: 1, title: "Instrument → Record (clean baseline path)")
            let baselineFixture = DecisionPathAgent.baselinePath
            log("  fixture steps: \(baselineFixture.stepTypes)")

            let tracesStore = try SQLiteTraceStore<AnyTraceableEvent>(fileURL: tracesURL)
            let baselineID = await DecisionPathAgent.recordPath(baselineFixture, store: tracesStore)
            try await tracesStore.flush()
            log("  recorded baseline run=\(baselineID.uuidString.lowercased())")
            log("  db=\(tracesURL.path)")

            // ── 2. Baseline pin (attestable export + baseline.sqlite) ────────
            banner(log, step: 2, title: "Baseline (pin golden run)")
            guard let baselineRun = try await tracesStore.getRun(id: baselineID) else {
                log("error: baseline run missing after record")
                return 2
            }

            // Pin a dedicated baseline DB by re-recording the same clean fixture
            // (Swift has no separate `dpk record` CLI pin; this is the library equivalent).
            let baselineStore = try SQLiteTraceStore<AnyTraceableEvent>(fileURL: baselineURL)
            let pinnedID = await DecisionPathAgent.recordPath(baselineFixture, store: baselineStore)
            try await baselineStore.flush()
            _ = await baselineStore.close()
            log("  pinned → \(baselineURL.path) (run=\(pinnedID.uuidString.lowercased()))")

            let attestable = try AttestableTrace(run: baselineRun, edges: [])
            struct TraceEnvelope: Encodable {
                let trace: AttestableTrace
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(TraceEnvelope(trace: attestable)).write(to: attestableURL)
            log("  wrote attestable trace → \(attestableURL.path)")
            log("  events=\(attestable.events.count) edges=\(attestable.edges.count)")

            // ── 3. Record regressed candidate ────────────────────────────────
            banner(log, step: 3, title: "Record candidate with CRITICAL-path regression")
            let candidateFixture = DecisionPathAgent.candidateRegressed
            log("  fixture steps: \(candidateFixture.stepTypes)")
            log("  regression: removed claimVerified (CRITICAL)")
            let candidateID = await DecisionPathAgent.recordPath(candidateFixture, store: tracesStore)
            try await tracesStore.flush()
            log("  recorded candidate run=\(candidateID.uuidString.lowercased())")

            guard let candidateRun = try await tracesStore.getRun(id: candidateID) else {
                log("error: candidate run missing after record")
                return 2
            }
            _ = await tracesStore.close()

            // ── 4. Compare → Gate (expect FAIL / HIGH) ───────────────────────
            banner(log, step: 4, title: "Compare → Gate (expect FAIL, HIGH)")
            let evaluator = AnyEquivalenceEvaluator<AnyTraceableEvent>(identifier: "any-exact") { a, b in
                (a.typeIdentifier == b.typeIdentifier && a.rawJSON == b.rawJSON) ? 1.0 : 0.0
            }
            let config = AlignmentConfiguration(
                profile: .strictAuditV1,
                equivalenceEvaluator: evaluator
            )
            log("  $ TraceAlignmentEngine.align (strictAuditV1)")
            let alignment = TraceAlignmentEngine(configuration: config)
                .align(base: baselineRun, comparison: candidateRun)
            let risk = alignment.regressionRisk
            log("  regression_level=\(risk.level.rawValue)")
            log("  reasoning=\(risk.reasoning)")

            if risk.level != .high {
                log("error: expected gate FAIL/high, got level=\(risk.level.rawValue)")
                return 1
            }
            log("  \(Self.markerGateFail)")
            log("  \(Self.markerGateLevel)")
            log("  removed/changed critical path caught (claimVerified)")

            // ── 5. Attest baseline (software P-256 / DPK-BINARY-V1) ──────────
            banner(log, step: 5, title: "Attest baseline (DPK-BINARY-V1 software P-256)")
            let key = SoftwareTraceAttestationKey()
            let document = try TraceAttestationDocument.signed(run: baselineRun, using: key)
            try document.jsonData(prettyPrinted: true).write(to: attestationURL)
            log("  wrote attestation → \(attestationURL.path)")
            log("  keyID=\(document.attestation.keyID)")

            // ── 6. Verify attestation ────────────────────────────────────────
            banner(log, step: 6, title: "Verify attestation")
            let loaded = try TraceAttestationDocument.decodeJSON(Data(contentsOf: attestationURL))
            let verification = loaded.verify()
            guard verification.isValid else {
                log("error: attest verify failed: \(String(describing: verification.failure))")
                return 1
            }
            log("  \(Self.markerAttestOK)")

            log("")
            log(String(repeating: "-", count: 72))
            log("\(Self.markerDemoOK): gate failed on regressed candidate; baseline attestation verified.")
            log("Claims kept honest: recorded path + CI gate + tamper-evident attest — not soundness.")
            return 0
        } catch {
            log("error: \(error)")
            return 2
        }
    }

    private static func banner(_ log: (String) -> Void, step: Int, title: String) {
        log("")
        log(String(repeating: "=", count: 72))
        log("  [\(step)] \(title)")
        log(String(repeating: "=", count: 72))
    }
}
