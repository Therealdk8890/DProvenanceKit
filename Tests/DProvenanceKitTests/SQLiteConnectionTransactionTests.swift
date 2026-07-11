import XCTest
@testable import DProvenanceKit
import Foundation

/// `SQLiteConnection.transaction` spans multiple statements (BEGIN … COMMIT) on a
/// connection that is shared across threads. Unserialized, two concurrent calls share
/// one SQLite transaction: the second BEGIN fails, its catch-path ROLLBACK discards
/// the first caller's staged writes, and the first caller's remaining statements then
/// auto-commit individually — a torn, non-atomic batch. The transaction lock makes
/// each block atomic again.
final class SQLiteConnectionTransactionTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    }

    override func tearDown() async throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
    }

    func testConcurrentTransactionsAreAtomicAndAllCommit() throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try db.execute("CREATE TABLE t (worker INTEGER NOT NULL, i INTEGER NOT NULL);")

        let workers = 8
        let rowsPerWorker = 50
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            do {
                try db.transaction {
                    let stmt = try db.prepare("INSERT INTO t (worker, i) VALUES (?, ?);")
                    for i in 0..<rowsPerWorker {
                        try stmt.bind(Int64(worker), at: 1)
                        try stmt.bind(Int64(i), at: 2)
                        _ = try stmt.step()
                        stmt.reset()
                    }
                }
            } catch {
                failures.append("worker \(worker): \(error)")
            }
        }

        XCTAssertEqual(failures.snapshot, [],
                       "no concurrent transaction may fail or be rolled back by a sibling")

        let count = try db.prepare("SELECT COUNT(*) FROM t;")
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(at: 0), Int64(workers * rowsPerWorker),
                       "every worker's batch must commit in full")
    }

    func testFailingTransactionStillRollsBackAtomically() throws {
        let db = try SQLiteConnection(fileURL: dbURL)
        try db.execute("CREATE TABLE t (x INTEGER NOT NULL);")

        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO t (x) VALUES (1);")
            throw Boom()
        })

        let count = try db.prepare("SELECT COUNT(*) FROM t;")
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(at: 0), 0, "a thrown block must leave no partial writes")
    }
}

/// Thread-safe error collector for `concurrentPerform`.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var snapshot: [String] {
        lock.withLock { messages }
    }
}
