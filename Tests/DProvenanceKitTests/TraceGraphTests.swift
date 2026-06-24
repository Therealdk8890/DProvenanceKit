import XCTest
@testable import DProvenanceKit
import Foundation

/// Coverage for the provenance-graph layer: structural + provenance validators,
/// store round-trips (lineage / impact / explain), the recursive-CTE cycle guard,
/// and the self-edge write guard. Reuses `TestEvent` from the SQLite test file.
final class TraceGraphTests: XCTestCase {

    // MARK: - Helpers

    private func node(_ payload: TestEvent, id: UUID) -> TraceEvent<TestEvent> {
        TraceEvent(
            id: id, runID: UUID(), contextID: "test", engineName: "test",
            schemaVersion: 1, sequence: 0, spanID: nil, parentSpanID: nil,
            payload: payload, timestamp: Date()
        )
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    // MARK: - Structural validator

    func testStructuralValidator_acyclicGraph_passes() {
        let a = UUID(), b = UUID(), c = UUID()
        let graph = TraceGraph<TestEvent>(
            nodes: [a: node(.processStarted, id: a), b: node(.stepCompleted(1), id: b), c: node(.processFinished, id: c)],
            edges: [
                TraceEdge(sourceID: a, targetID: b, type: .derivedFrom),
                TraceEdge(sourceID: b, targetID: c, type: .generatedFrom)
            ]
        )
        XCTAssertNoThrow(try TraceGraphValidator<TestEvent>().validateStructuralIntegrity(graph: graph))
    }

    func testStructuralValidator_selfEdge_throws() {
        let a = UUID()
        let graph = TraceGraph<TestEvent>(
            nodes: [a: node(.processStarted, id: a)],
            edges: [TraceEdge(sourceID: a, targetID: a, type: .derivedFrom)]
        )
        XCTAssertThrowsError(try TraceGraphValidator<TestEvent>().validateStructuralIntegrity(graph: graph)) { error in
            guard case TraceGraphValidationError.selfReferentialEdge = error else {
                return XCTFail("expected selfReferentialEdge, got \(error)")
            }
        }
    }

    func testStructuralValidator_cycle_throws() {
        let a = UUID(), b = UUID()
        let graph = TraceGraph<TestEvent>(
            nodes: [a: node(.processStarted, id: a), b: node(.processFinished, id: b)],
            edges: [
                TraceEdge(sourceID: a, targetID: b, type: .derivedFrom),
                TraceEdge(sourceID: b, targetID: a, type: .derivedFrom)
            ]
        )
        XCTAssertThrowsError(try TraceGraphValidator<TestEvent>().validateStructuralIntegrity(graph: graph)) { error in
            guard case TraceGraphValidationError.structuralCycleDetected = error else {
                return XCTFail("expected structuralCycleDetected, got \(error)")
            }
        }
    }

    // MARK: - Provenance validator

    func testProvenanceValidator_flagsOrphanSectionAndUnusedFact() {
        let fact = UUID(), section = UUID()
        let graph = TraceGraph<TestEvent>(
            nodes: [fact: node(.processStarted, id: fact), section: node(.processFinished, id: section)],
            edges: [] // fact has no outgoing edge, section has no incoming edge
        )
        let validator = TraceGraphProvenanceValidator<TestEvent>(
            generatedSectionIdentifier: "processFinished",
            factExtractedIdentifier: "processStarted"
        )
        let anomalies = validator.detectAnomalies(graph: graph)
        XCTAssertEqual(anomalies.count, 2)
        XCTAssertTrue(anomalies.contains { $0.contains("Orphan generated section") })
        XCTAssertTrue(anomalies.contains { $0.contains("Unused extracted fact") })
    }

    func testProvenanceValidator_cleanGraph_noAnomalies() {
        let fact = UUID(), section = UUID()
        let graph = TraceGraph<TestEvent>(
            nodes: [fact: node(.processStarted, id: fact), section: node(.processFinished, id: section)],
            edges: [TraceEdge(sourceID: fact, targetID: section, type: .informed)]
        )
        let validator = TraceGraphProvenanceValidator<TestEvent>(
            generatedSectionIdentifier: "processFinished",
            factExtractedIdentifier: "processStarted"
        )
        XCTAssertTrue(validator.detectAnomalies(graph: graph).isEmpty)
    }

    // MARK: - Store round-trips

    func testInMemoryStore_lineageImpactExplain() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        let ids = await DProvenanceKit<TestEvent>.run(contextID: "g", store: store) { () -> [UUID] in
            let a = DProvenanceKit<TestEvent>.record(.processStarted)!
            let b = DProvenanceKit<TestEvent>.record(.stepCompleted(1))!
            let c = DProvenanceKit<TestEvent>.record(.processFinished)!
            DProvenanceKit<TestEvent>.link(source: a, target: b, type: .informed)
            DProvenanceKit<TestEvent>.link(source: b, target: c, type: .derivedFrom)
            return [a, b, c]
        }
        try await store.flush()
        let (a, b, c) = (ids[0], ids[1], ids[2])

        let lineage = try await store.lineage(of: c)
        XCTAssertEqual(lineage.edges.count, 2)
        XCTAssertEqual(Set(lineage.nodes.keys), Set([a, b, c]))

        let impact = try await store.impact(of: a)
        XCTAssertEqual(impact.edges.count, 2)

        let explanation = try await store.explain(id: c)
        XCTAssertEqual(explanation.derivedFrom.count, 1)
        XCTAssertTrue(explanation.informedBy.isEmpty)
    }

    func testSQLiteStore_lineageAndImpactRoundTrip() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url)

        let ids = await DProvenanceKit<TestEvent>.run(contextID: "g", store: store) { () -> [UUID] in
            let a = DProvenanceKit<TestEvent>.record(.processStarted)!
            let b = DProvenanceKit<TestEvent>.record(.processFinished)!
            DProvenanceKit<TestEvent>.link(source: a, target: b, type: .derivedFrom)
            return [a, b]
        }
        try await store.flush()
        let (a, b) = (ids[0], ids[1])

        // Exercises the recursive CTE + the persisted-id fix (getEvents joins on e.id).
        let lineage = try await store.lineage(of: b)
        XCTAssertEqual(lineage.edges, [TraceEdge(sourceID: a, targetID: b, type: .derivedFrom)])
        XCTAssertEqual(Set(lineage.nodes.keys), Set([a, b]))

        let impact = try await store.impact(of: a)
        XCTAssertEqual(impact.edges.count, 1)
    }

    func testSQLiteStore_cyclicEdges_traversalTerminates() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteTraceStore<TestEvent>(fileURL: url)

        let ids = await DProvenanceKit<TestEvent>.run(contextID: "cycle", store: store) { () -> [UUID] in
            let a = DProvenanceKit<TestEvent>.record(.processStarted)!
            let b = DProvenanceKit<TestEvent>.record(.processFinished)!
            DProvenanceKit<TestEvent>.link(source: a, target: b, type: .derivedFrom)
            DProvenanceKit<TestEvent>.link(source: b, target: a, type: .derivedFrom) // cycle
            return [a, b]
        }
        try await store.flush()

        // Regression for the cycle guard: the recursive CTE must terminate (UNION
        // dedup) and return the two distinct edges rather than looping forever.
        let lineage = try await store.lineageEdges(of: ids[0])
        XCTAssertEqual(lineage.count, 2)
        let impact = try await store.impactEdges(of: ids[0])
        XCTAssertEqual(impact.count, 2)
    }

    func testLink_rejectsSelfReferentialEdge() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        let id = await DProvenanceKit<TestEvent>.run(contextID: "self", store: store) { () -> UUID in
            let a = DProvenanceKit<TestEvent>.record(.processStarted)!
            DProvenanceKit<TestEvent>.link(source: a, target: a, type: .derivedFrom)
            return a
        }
        try await store.flush()
        let edges = try await store.lineageEdges(of: id)
        XCTAssertTrue(edges.isEmpty, "a self-referential edge must be rejected at the write boundary")
    }

    func testTraceExplanationFormatting() {
        let explanation = TraceExplanation(
            targetNodeID: UUID(),
            targetNodeSummary: "Generated demand paragraph",
            informedBy: ["fact: amount owed"],
            derivedFrom: ["evidence: invoice"]
        )
        let text = explanation.formatted()
        XCTAssertTrue(text.contains("Generated demand paragraph"))
        XCTAssertTrue(text.contains("Informed By:"))
        XCTAssertTrue(text.contains("fact: amount owed"))
        XCTAssertTrue(text.contains("Derived From:"))
        XCTAssertTrue(text.contains("evidence: invoice"))
    }
}
