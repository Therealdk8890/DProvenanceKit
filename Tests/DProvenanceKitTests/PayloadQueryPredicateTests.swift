import XCTest
@testable import DProvenanceKit
import Foundation

/// Covers `matching(where:)` — querying by payload *value*, not just step presence —
/// across both local stores, in combination with structural predicates and negation.
final class PayloadQueryPredicateTests: XCTestCase {

    /// Six runs; run `i` records `stepCompleted(i)`.
    private func seed(_ store: any TraceStore<TestEvent>) async {
        for i in 0..<6 {
            await DProvenanceKit<TestEvent>.run(contextID: "run\(i)", store: store) {
                DProvenanceKit<TestEvent>.record(.processStarted)
                DProvenanceKit<TestEvent>.record(.stepCompleted(i))
                DProvenanceKit<TestEvent>.record(.processFinished)
            }
        }
    }

    /// Runs with a `stepCompleted` value >= 4  → i in {4, 5}.
    private var highStep: TraceQueryDSL<TestEvent> {
        TraceQueryDSL<TestEvent>().matching(step: "stepCompleted") {
            if case .stepCompleted(let n) = $0 { return n >= 4 }
            return false
        }
    }

    private func sqliteStore() throws -> (SQLiteTraceStore<TestEvent>, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        return (try SQLiteTraceStore<TestEvent>(fileURL: url), url)
    }

    func testInMemoryValuePredicate() async throws {
        let store = InMemoryTraceStore<TestEvent>()
        await seed(store)
        let runs = try await store.queryRuns(highStep)
        XCTAssertEqual(Set(runs.map(\.contextID)), ["run4", "run5"])
    }

    func testSQLiteValuePredicate() async throws {
        let (store, url) = try sqliteStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(store)
        let runs = try await store.queryRuns(highStep)
        XCTAssertEqual(Set(runs.map(\.contextID)), ["run4", "run5"])
    }

    /// The value predicate must return the same runs from both stores (parity by
    /// construction: SQLite hydrates a candidate superset, then runs the same evaluator).
    func testStoreParity() async throws {
        let mem = InMemoryTraceStore<TestEvent>()
        let (sql, url) = try sqliteStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(mem)
        await seed(sql)

        let memSet = Set(try await mem.queryRuns(highStep).map(\.contextID))
        let sqlSet = Set(try await sql.queryRuns(highStep).map(\.contextID))
        XCTAssertEqual(memSet, sqlSet)
        XCTAssertEqual(memSet, ["run4", "run5"])
    }

    func testCombinedWithStructural() async throws {
        let (store, url) = try sqliteStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(store)
        // Structural AND value: has a processFinished step AND a high stepCompleted.
        let q = TraceQueryDSL<TestEvent>()
            .requiring(step: "processFinished")
            .matching(step: "stepCompleted") { if case .stepCompleted(let n) = $0 { return n >= 4 }; return false }
        let runs = try await store.queryRuns(q)
        XCTAssertEqual(Set(runs.map(\.contextID)), ["run4", "run5"])
    }

    /// `excluding(highStep)` = runs with NO high stepCompleted → exercises the compiler's
    /// NOT-over-payload-predicate path (which must fall back to match-all + in-process
    /// refine, not `EXCEPT(all)` = ∅).
    func testNegationOfValuePredicateSQLite() async throws {
        let (store, url) = try sqliteStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(store)
        let runs = try await store.queryRuns(TraceQueryDSL<TestEvent>().excluding(highStep))
        XCTAssertEqual(Set(runs.map(\.contextID)), ["run0", "run1", "run2", "run3"])
    }

    func testLimitAppliesAfterValueFilter() async throws {
        let (store, url) = try sqliteStore()
        defer { try? FileManager.default.removeItem(at: url) }
        await seed(store)
        // Two runs match; limit 1 must return exactly one MATCHING run (not one candidate).
        let runs = try await store.queryRuns(highStep, limit: 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(["run4", "run5"].contains(runs[0].contextID))
    }

    /// A closure can't cross the wire, so encoding a value-predicate DSL (the cloud path)
    /// must fail loudly rather than silently drop the predicate.
    func testEncodingAValuePredicateThrows() {
        XCTAssertThrowsError(try JSONEncoder().encode(highStep))
    }

    /// Structural-only queries must still encode (the negation builder over structural
    /// nodes stays serializable).
    func testStructuralQueryStillEncodes() throws {
        let q = TraceQueryDSL<TestEvent>().requiring(step: "processFinished")
        XCTAssertNoThrow(try JSONEncoder().encode(q))
    }
}
