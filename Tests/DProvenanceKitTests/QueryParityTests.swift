import XCTest
@testable import DProvenanceKit
import Foundation

/// Guards the contract that a `TraceQueryDSL` returns the SAME runs whether it is
/// evaluated in memory (`TraceQueryNode.evaluate`) or compiled to SQL
/// (`TraceQueryCompiler`). The two backends are independent implementations of one
/// query language; if they drift, a diff or regression query becomes
/// store-dependent — a correctness bug, not a performance detail.
///
/// Reuses the `TestEvent` type defined in `SQLiteStressTests.swift`.
final class QueryParityTests: XCTestCase {

    /// Records the *same* scenario into a fresh in-memory store and a fresh SQLite
    /// store, runs `query` against both, and returns the matched runs' contextIDs
    /// (sorted) from each. ContextIDs are used rather than runIDs because each
    /// store mints its own `runID`; the contextID is the stable, caller-controlled
    /// identity shared across both runs.
    private func matches(
        scenario: @Sendable (_ record: @escaping (TestEvent) -> Void) -> Void,
        query: TraceQueryDSL<TestEvent>,
        contextID: String = "case"
    ) async throws -> (memory: [String], sqlite: [String]) {

        // In-memory backend
        let memStore = InMemoryTraceStore<TestEvent>()
        await DProvenanceKit<TestEvent>.run(contextID: contextID, store: memStore) {
            scenario { DProvenanceKit<TestEvent>.record($0) }
        }
        let memMatched = try await memStore.queryRuns(query).map(\.contextID).sorted()

        // SQLite backend
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sqlStore = try SQLiteTraceStore<TestEvent>(fileURL: url)
        await DProvenanceKit<TestEvent>.run(contextID: contextID, store: sqlStore) {
            scenario { DProvenanceKit<TestEvent>.record($0) }
        }
        try await sqlStore.flush()
        let sqlMatched = try await sqlStore.queryRuns(query).map(\.contextID).sorted()

        return (memMatched, sqlMatched)
    }

    // MARK: - The regression this whole file exists for

    /// `.before(step:precededBy:)` means "precededBy occurs before the FIRST
    /// `step`." In `[errorDetected, stepCompleted, errorDetected]`, stepCompleted
    /// sits between the two errorDetected events, so it does NOT precede the first
    /// one — both backends must report no match.
    ///
    /// Before the compiler fix, the SQL path matched "any `step` with an earlier
    /// `precededBy`" ordered by timestamp, so it matched this run (via the second
    /// errorDetected) while the in-memory evaluator did not. This test fails on
    /// that implementation and passes once `.before` anchors to `MIN(sequence)`.
    func testBeforeAnchorsToFirstOccurrence() async throws {
        let (mem, sql) = try await matches(
            scenario: { record in
                record(.errorDetected)
                record(.stepCompleted(1))
                record(.errorDetected)
            },
            query: TraceQueryDSL<TestEvent>()
                .requiring(step: "errorDetected", precededBy: "stepCompleted")
        )
        XCTAssertEqual(mem, sql, "InMemory and SQLite disagree on .before semantics")
        XCTAssertTrue(mem.isEmpty, "stepCompleted does not precede the FIRST errorDetected")
    }

    /// `.sequence` must order by the causal `sequence`, not wall-clock time. Events
    /// recorded in a tight burst can share a timestamp; a timestamp-chained join
    /// then finds no strictly-increasing path and wrongly reports no subsequence,
    /// while the in-memory evaluator (sequence-ordered) finds it. Recording the
    /// three steps back-to-back makes a tie likely; the assertion is on agreement,
    /// so it holds regardless of whether a tie actually occurs on a given run.
    func testSequenceUsesCausalOrderNotTimestamp() async throws {
        let (mem, sql) = try await matches(
            scenario: { record in
                record(.processStarted)
                record(.errorDetected)
                record(.processFinished)
            },
            query: TraceQueryDSL<TestEvent>()
                .requiring(sequence: ["processStarted", "errorDetected", "processFinished"])
        )
        XCTAssertEqual(mem, sql, "InMemory and SQLite disagree on .sequence ordering")
        XCTAssertEqual(mem, ["case"], "The declared subsequence is present in causal order")
    }

    // MARK: - Broad guard against future drift

    /// Every operator, over one shared scenario, must agree across both backends.
    /// Extend `queries` whenever a new operator or edge case is added.
    func testOperatorParityMatrix() async throws {
        let scenario: @Sendable (_ record: @escaping (TestEvent) -> Void) -> Void = { record in
            record(.processStarted)
            record(.stepCompleted(1))
            record(.errorDetected)
            record(.stepCompleted(2))
            record(.processFinished)
        }

        let queries: [(name: String, query: TraceQueryDSL<TestEvent>)] = [
            ("contains",     TraceQueryDSL<TestEvent>().requiring(step: "errorDetected")),
            ("contains-miss",TraceQueryDSL<TestEvent>().requiring(step: "rollback")),
            ("missing",      TraceQueryDSL<TestEvent>().missing(step: "rollback")),
            ("missing-hit",  TraceQueryDSL<TestEvent>().missing(step: "errorDetected")),
            ("after",        TraceQueryDSL<TestEvent>().requiring(step: "processStarted", followedBy: "processFinished")),
            ("after-miss",   TraceQueryDSL<TestEvent>().requiring(step: "processFinished", followedBy: "processStarted")),
            ("before",       TraceQueryDSL<TestEvent>().requiring(step: "errorDetected", precededBy: "processStarted")),
            ("before-miss",  TraceQueryDSL<TestEvent>().requiring(step: "processStarted", precededBy: "errorDetected")),
            ("sequence",     TraceQueryDSL<TestEvent>().requiring(sequence: ["processStarted", "errorDetected", "processFinished"])),
            ("sequence-miss",TraceQueryDSL<TestEvent>().requiring(sequence: ["processFinished", "processStarted"])),
            ("and",          TraceQueryDSL<TestEvent>().requiring(step: "errorDetected").missing(step: "rollback")),
        ]

        for case let (name, query) in queries {
            let (mem, sql) = try await matches(scenario: scenario, query: query)
            XCTAssertEqual(mem, sql, "Backend divergence on query: \(name)")
        }
    }
}
