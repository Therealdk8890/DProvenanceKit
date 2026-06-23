import Foundation
import SQLite3

// SQLite's SQLITE_TRANSIENT sentinel is a C macro the Swift importer doesn't
// surface, so we reconstruct it. Passing it as the destructor argument tells
// SQLite to make its own private copy of the bound bytes *before the bind call
// returns*. Passing `nil` (SQLITE_STATIC) instead makes SQLite keep the caller's
// pointer and read it lazily at step() time — a use-after-free for the transient
// pointers we hand it below (`String` bridges and `Data.withUnsafeBytes` buffers
// are both dead by the time the statement is stepped).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(Int32, String?)
    case executeFailed(Int32, String?)
    case prepareFailed(Int32, String?)
    case stepFailed(Int32, String?)
    case bindFailed(Int32, String?)
    
    public var description: String {
        switch self {
        case .openFailed(let code, let msg): return "Open failed (\(code)): \(msg ?? "Unknown")"
        case .executeFailed(let code, let msg): return "Execute failed (\(code)): \(msg ?? "Unknown")"
        case .prepareFailed(let code, let msg): return "Prepare failed (\(code)): \(msg ?? "Unknown")"
        case .stepFailed(let code, let msg): return "Step failed (\(code)): \(msg ?? "Unknown")"
        case .bindFailed(let code, let msg): return "Bind failed (\(code)): \(msg ?? "Unknown")"
        }
    }
}

public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dprovenancekit.sqlite", attributes: .concurrent)

    public init(fileURL: URL) throws {
        // Use SQLITE_OPEN_FULLMUTEX because we share the connection pointer across threads
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var tempDB: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &tempDB, flags, nil)
        guard result == SQLITE_OK else {
            let msg = tempDB.flatMap { String(cString: sqlite3_errmsg($0)) }
            sqlite3_close_v2(tempDB)
            throw SQLiteError.openFailed(result, msg)
        }
        self.db = tempDB
        
        // Enable WAL mode
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;") // Safe with WAL
        try execute("PRAGMA temp_store=MEMORY;")
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }
    
    public func execute(_ sql: String) throws {
        try queue.sync(flags: .barrier) {
            var errMsg: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if result != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) }
                sqlite3_free(errMsg)
                throw SQLiteError.executeFailed(result, msg)
            }
        }
    }
    
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN TRANSACTION;")
        do {
            let result = try block()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        return try queue.sync {
            var stmt: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard result == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.prepareFailed(result, msg)
            }
            return SQLiteStatement(stmt: stmt, db: db)
        }
    }
}

public final class SQLiteStatement {
    let stmt: OpaquePointer?
    let db: OpaquePointer?
    
    init(stmt: OpaquePointer?, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }
    
    deinit {
        sqlite3_finalize(stmt)
    }
    
    public func bind(_ value: String, at index: Int32) throws {
        // SQLITE_TRANSIENT: SQLite copies the bytes during this call, so the
        // temporary C-string Swift bridges from `value` need not outlive it.
        let result = sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        guard result == SQLITE_OK else { throw SQLiteError.bindFailed(result, String(cString: sqlite3_errmsg(db))) }
    }
    
    public func bind(_ value: Int64, at index: Int32) throws {
        let result = sqlite3_bind_int64(stmt, index, value)
        guard result == SQLITE_OK else { throw SQLiteError.bindFailed(result, String(cString: sqlite3_errmsg(db))) }
    }
    
    public func bind(_ value: Data, at index: Int32) throws {
        // SQLITE_TRANSIENT: SQLite copies the blob before withUnsafeBytes returns,
        // so the buffer pointer (invalid past the closure) is never read at step().
        let result = value.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else { throw SQLiteError.bindFailed(result, String(cString: sqlite3_errmsg(db))) }
    }
    
    public func bindNull(at index: Int32) throws {
        let result = sqlite3_bind_null(stmt, index)
        guard result == SQLITE_OK else { throw SQLiteError.bindFailed(result, String(cString: sqlite3_errmsg(db))) }
    }
    
    public func step() throws -> Bool {
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SQLiteError.stepFailed(result, String(cString: sqlite3_errmsg(db)))
    }
    
    public func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }
    
    // Column extractors
    public func columnString(at index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
    
    public func columnInt64(at index: Int32) -> Int64 {
        return sqlite3_column_int64(stmt, index)
    }
    
    public func columnInt(at index: Int32) -> Int {
        return Int(sqlite3_column_int64(stmt, index))
    }
    
    public func columnData(at index: Int32) -> Data {
        let count = sqlite3_column_bytes(stmt, index)
        if let ptr = sqlite3_column_blob(stmt, index), count > 0 {
            return Data(bytes: ptr, count: Int(count))
        }
        return Data()
    }
}
