import Foundation
import XCTest
@testable import DProvenanceKit

private struct SchemaMigrationEvent: TraceableEvent {
    let value: String

    var typeIdentifier: String { "schema-migration" }
    var priority: TracePriority { .diagnostic }
}

/// The span/schema-version backfill in `SQLiteTraceStore.init` checks column
/// presence before ALTERing (instead of `try?`-swallowing duplicate-column
/// errors). These tests pin the migration across every legacy shape: fresh,
/// fully legacy, partially migrated, and — because SQLite compares identifiers
/// case-insensitively while Swift string comparison does not — legacy columns
/// declared in non-lowercase case.
final class SQLiteSchemaMigrationTests: XCTestCase {
    func testFreshSchemaContainsEachBackfilledColumnOnce() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }

        _ = try SQLiteTraceStore<SchemaMigrationEvent>(fileURL: url)
        _ = try SQLiteTraceStore<SchemaMigrationEvent>(fileURL: url)

        let columns = try traceEventColumns(at: url)
        XCTAssertEqual(columns.filter { $0 == "span_id" }.count, 1)
        XCTAssertEqual(columns.filter { $0 == "parent_span_id" }.count, 1)
        XCTAssertEqual(columns.filter { $0 == "schema_version" }.count, 1)
    }

    func testLegacySchemaAddsMissingColumns() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }

        try createLegacyTable(at: url, extraColumns: "")

        _ = try SQLiteTraceStore<SchemaMigrationEvent>(fileURL: url)

        let columns = try traceEventColumns(at: url)
        XCTAssertTrue(columns.contains("span_id"))
        XCTAssertTrue(columns.contains("parent_span_id"))
        XCTAssertTrue(columns.contains("schema_version"))
    }

    func testPartiallyMigratedSchemaAddsOnlyTheMissingColumns() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }

        try createLegacyTable(at: url, extraColumns: "span_id TEXT,")

        _ = try SQLiteTraceStore<SchemaMigrationEvent>(fileURL: url)

        let columns = try traceEventColumns(at: url)
        XCTAssertEqual(columns.filter { $0 == "span_id" }.count, 1)
        XCTAssertEqual(columns.filter { $0 == "parent_span_id" }.count, 1)
        XCTAssertEqual(columns.filter { $0 == "schema_version" }.count, 1)
    }

    /// SQLite treats `SPAN_ID` and `span_id` as the same column, so a legacy
    /// database with uppercase declarations must open cleanly — a case-sensitive
    /// presence check would re-ALTER and throw "duplicate column name" on every
    /// launch, bricking init for a database the old `try?` path handled fine.
    func testUppercaseLegacyColumnsOpenWithoutDuplicateAlter() throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }

        try createLegacyTable(
            at: url,
            extraColumns: "SPAN_ID TEXT, PARENT_SPAN_ID TEXT, SCHEMA_VERSION INTEGER NOT NULL DEFAULT 1,"
        )

        XCTAssertNoThrow(_ = try SQLiteTraceStore<SchemaMigrationEvent>(fileURL: url))

        let lowered = try traceEventColumns(at: url).map { $0.lowercased() }
        XCTAssertEqual(lowered.filter { $0 == "span_id" }.count, 1)
        XCTAssertEqual(lowered.filter { $0 == "parent_span_id" }.count, 1)
        XCTAssertEqual(lowered.filter { $0 == "schema_version" }.count, 1)
    }

    // MARK: - Helpers

    /// A pre-backfill `trace_events` table; `extraColumns` injects the columns a
    /// given scenario already has (trailing comma included by the caller).
    private func createLegacyTable(at url: URL, extraColumns: String) throws {
        let database = try SQLiteConnection(fileURL: url)
        try database.execute("""
        CREATE TABLE trace_events (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            context_id TEXT NOT NULL,
            priority INTEGER NOT NULL,
            sequence INTEGER NOT NULL,
            engine TEXT,
            \(extraColumns)
            type TEXT NOT NULL,
            payload BLOB NOT NULL,
            timestamp INTEGER NOT NULL
        );
        """)
    }

    private func traceEventColumns(at url: URL) throws -> [String] {
        let database = try SQLiteConnection(fileURL: url)
        let statement = try database.prepare("PRAGMA table_info(trace_events);")
        var columns: [String] = []
        while try statement.step() {
            if let name = statement.columnString(at: 1) {
                columns.append(name)
            }
        }
        return columns
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteSchemaMigrationTests-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }
}
