import XCTest
@testable import DProvenanceKit

/// Pins SEMANTICS.md Invariant E (causal preservation) for `.linear` profiles:
/// reordering CRITICAL steps must surface as `.reordered` and drive
/// RegressionRisk to `.high` in every alignment mode — a CI gate on
/// `strictAuditV1` must not be blind to a dependency inversion. Non-critical
/// reorder in `.linear` stays suppressed (the common, benign case).
final class LinearCriticalReorderTests: XCTestCase {

    enum PipelineEvent: TraceableEvent {
        case prompt
        case createCustomer
        case generateInvoice
        case response
        case telemetryPing

        var typeIdentifier: String {
            switch self {
            case .prompt: return "prompt"
            case .createCustomer: return "create_customer"
            case .generateInvoice: return "generate_invoice"
            case .response: return "response"
            case .telemetryPing: return "telemetry_ping"
            }
        }

        var priority: TracePriority {
            switch self {
            case .prompt, .createCustomer, .generateInvoice, .response: return .critical
            case .telemetryPing: return .telemetry
            }
        }
    }

    enum StructuralEvent: TraceableEvent {
        case stepA
        case stepB
        case anchorStart
        case anchorEnd

        var typeIdentifier: String {
            switch self {
            case .stepA: return "stepA"
            case .stepB: return "stepB"
            case .anchorStart: return "anchor_start"
            case .anchorEnd: return "anchor_end"
            }
        }

        var priority: TracePriority { .structural }
    }

    private func makeRun<T: TraceableEvent>(_ payloads: [T]) -> TraceRun<T> {
        let id = UUID()
        let events = payloads.enumerated().map { index, payload in
            TraceEvent(
                runID: id,
                contextID: "reorder_ctx",
                engineName: "engine1",
                schemaVersion: 1,
                sequence: UInt64(index),
                spanID: nil,
                parentSpanID: nil,
                payload: payload,
                timestamp: Date()
            )
        }
        return TraceRun(runID: id, contextID: "reorder_ctx", events: events)
    }

    private func exactEvaluator<T: TraceableEvent>(_ type: T.Type) -> AnyEquivalenceEvaluator<T> {
        AnyEquivalenceEvaluator<T>(identifier: "exact") { a, b in
            a.typeIdentifier == b.typeIdentifier ? 1.0 : 0.0
        }
    }

    func testLinearProfileFlagsCriticalReorderAsHighRegression() {
        // The SEMANTICS.md example: invoice generated BEFORE the customer
        // exists. strictAuditV1 is the .linear profile.
        let base = makeRun([PipelineEvent.prompt, .createCustomer, .generateInvoice, .response])
        let comparison = makeRun([PipelineEvent.prompt, .generateInvoice, .createCustomer, .response])

        let config = AlignmentConfiguration(
            profile: .strictAuditV1,
            equivalenceEvaluator: exactEvaluator(PipelineEvent.self)
        )
        let result = TraceAlignmentEngine(configuration: config).align(base: base, comparison: comparison)

        let reordered = result.alignments.filter { $0.state.isReordered }
        XCTAssertEqual(
            Set(reordered.compactMap { $0.baseEvent?.payload.typeIdentifier }),
            ["create_customer", "generate_invoice"],
            "the swapped critical pair must both surface as reordered"
        )
        XCTAssertEqual(result.regressionRisk.level, .high)
        XCTAssertTrue(result.regressionRisk.reasoning.contains("reordered"),
                      "risk reasoning should name the reorder: \(result.regressionRisk.reasoning)")
    }

    func testLinearProfileStillSuppressesNonCriticalReorder() {
        // Anchored so the matcher has stable endpoints; only the two
        // structural steps swap. Linear mode keeps this benign.
        let base = makeRun([StructuralEvent.anchorStart, .stepA, .stepB, .anchorEnd])
        let comparison = makeRun([StructuralEvent.anchorStart, .stepB, .stepA, .anchorEnd])

        let config = AlignmentConfiguration(
            profile: .strictAuditV1,
            equivalenceEvaluator: exactEvaluator(StructuralEvent.self)
        )
        let result = TraceAlignmentEngine(configuration: config).align(base: base, comparison: comparison)

        XCTAssertTrue(result.alignments.allSatisfy { !$0.state.isReordered },
                      "non-critical reorder stays suppressed in .linear mode")
        XCTAssertEqual(result.regressionRisk.level, RegressionRisk.Level.none)
    }
}
