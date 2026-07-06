import XCTest
@testable import DProvenanceKit
import Foundation

/// Covers `record(_:derivedFrom:)`, which records an event and wires its lineage edge
/// in one call so the shipped lineage/impact/explain graph is reachable without manual
/// UUID bookkeeping.
final class RecordDerivedFromTests: XCTestCase {

    func testDerivedFromBuildsLineageImpactAndExplain_InMemory() async throws {
        let store = InMemoryTraceStore<TestEvent>()

        let (docID, decisionID) = await DProvenanceKit<TestEvent>.run(
            contextID: "lineage", store: store
        ) { () -> (UUID, UUID) in
            let doc = DProvenanceKit<TestEvent>.record(.processStarted)!
            let decision = DProvenanceKit<TestEvent>.record(.processFinished, derivedFrom: doc)!
            return (doc, decision)
        }

        // Forward: doc → decision, as a derivedFrom edge.
        let impact = try await store.impactEdges(of: docID)
        XCTAssertTrue(
            impact.contains { $0.sourceID == docID && $0.targetID == decisionID && $0.type == .derivedFrom },
            "record(derivedFrom:) must create a parent → new-event derivedFrom edge")

        // Backward: the derived event's lineage reaches its parent.
        let lineage = try await store.lineage(of: decisionID)
        XCTAssertTrue(lineage.nodes.keys.contains(docID))

        // Explanation attributes the derivation.
        let explanation = try await store.explain(id: decisionID)
        XCTAssertFalse(explanation.derivedFrom.isEmpty, "explain must attribute the derivation")
    }

    func testMultipleParents() async throws {
        let store = InMemoryTraceStore<TestEvent>()

        let (a, b, c) = await DProvenanceKit<TestEvent>.run(
            contextID: "multi", store: store
        ) { () -> (UUID, UUID, UUID) in
            let a = DProvenanceKit<TestEvent>.record(.processStarted)!
            let b = DProvenanceKit<TestEvent>.record(.errorDetected)!
            let c = DProvenanceKit<TestEvent>.record(.processFinished, derivedFrom: [a, b])!
            return (a, b, c)
        }

        let lineage = try await store.lineage(of: c)
        XCTAssertTrue(lineage.nodes.keys.contains(a))
        XCTAssertTrue(lineage.nodes.keys.contains(b))
    }

    func testCustomEdgeType() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        let (src, derived) = await DProvenanceKit<TestEvent>.run(
            contextID: "typed", store: store
        ) { () -> (UUID, UUID) in
            let src = DProvenanceKit<TestEvent>.record(.processStarted)!
            let derived = DProvenanceKit<TestEvent>.record(.errorDetected, derivedFrom: src, type: .correctedBy)!
            return (src, derived)
        }
        let impact = try await store.impactEdges(of: src)
        XCTAssertTrue(impact.contains { $0.targetID == derived && $0.type == .correctedBy })
    }

    func testDerivedFromPersistsThroughSQLite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url)

        let (docID, decisionID) = await DProvenanceKit<TestEvent>.run(
            contextID: "lineage", store: store
        ) { () -> (UUID, UUID) in
            let doc = DProvenanceKit<TestEvent>.record(.processStarted)!
            let decision = DProvenanceKit<TestEvent>.record(.processFinished, derivedFrom: doc)!
            return (doc, decision)
        }

        let impact = try await store.impactEdges(of: docID)
        XCTAssertTrue(impact.contains { $0.sourceID == docID && $0.targetID == decisionID })
    }
}
