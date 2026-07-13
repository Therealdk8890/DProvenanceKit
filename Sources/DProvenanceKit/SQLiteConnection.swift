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

/// How a `SQLiteConnection` opens the database file.
public enum SQLiteOpenMode: Sendable, Equatable {
    /// Open read-write, creating the file if it does not exist (the historical default).
    case readWriteCreate
    /// Open an existing database strictly read-only. Opening fails if the file does not
    /// exist — a mistyped path can no longer silently create an empty store — and any
    /// write through the connection fails with `SQLITE_READONLY`. The main database file
    /// is never modified.
    ///
    /// Caveat: a WAL-mode file with no `-wal` companion at all — a store copied,
    /// exported, or rotated as a single bare file — cannot be read through a read-only
    /// connection: reads fail with `SQLITE_CANTOPEN`. Whenever a `-wal` sits next to
    /// the file (a live writer, a crashed writer, or a cleanly closed store on Apple
    /// platforms, which persist an empty `-wal`), plain read-only reads work, even if
    /// the `-shm` is missing. For bare single-file stores, use `.readOnlyImmutable`.
    case readOnly
    /// Open strictly read-only with SQLite's `immutable=1` option: no locks are taken
    /// and no `-shm`/`-wal` files are read or created, which makes cold WAL-mode files
    /// readable (see `.readOnly`). ONLY safe for files no live writer can touch — an
    /// archived or copied store, or one whose owning process has exited. If another
    /// connection writes the file while it is open in this mode, reads may return
    /// corrupt results rather than merely stale ones.
    case readOnlyImmutable
}

public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dprovenancekit.sqlite", attributes: .concurrent)

    public init(fileURL: URL, mode: SQLiteOpenMode = .readWriteCreate) throws {
        // Use SQLITE_OPEN_FULLMUTEX because we share the connection pointer across threads
        let modeFlags: Int32
        let path: String
        switch mode {
        case .readWriteCreate:
            modeFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
            path = fileURL.path
        case .readOnly:
            modeFlags = SQLITE_OPEN_READONLY
            path = fileURL.path
        case .readOnlyImmutable:
            // immutable is only expressible through a URI filename; the file: URL form
            // percent-encodes spaces and other characters the URI parser would trip on.
            modeFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            path = URL(fileURLWithPath: fileURL.path).absoluteString + "?immutable=1"
        }
        let flags = modeFlags | SQLITE_OPEN_FULLMUTEX
        var tempDB: OpaquePointer?
        let result = sqlite3_open_v2(path, &tempDB, flags, nil)
        guard result == SQLITE_OK else {
            let msg = tempDB.flatMap { String(cString: sqlite3_errmsg($0)) }
            sqlite3_close_v2(tempDB)
            throw SQLiteError.openFailed(result, msg)
        }
        self.db = tempDB

        // Wait up to 5s for a lock instead of failing instantly with SQLITE_BUSY.
        // A second connection (e.g. the inspector UI reading while the app writes)
        // can collide with a WAL checkpoint; the default 0ms timeout turns that
        // transient contention into a hard error. Blocking briefly is the standard
        // remedy and is bounded, so it never deadlocks the writer.
        //
        // Installed before any file-touching pragma: `journal_mode=WAL` below is
        // this connection's first read of the database, and it can land inside
        // another connection's close-time checkpoint (closing the last connection
        // to a WAL database briefly holds the file exclusively). With no busy
        // handler yet, that collision throws "database is locked" from init.
        // busy_timeout itself only installs the handler — it does no file I/O.
        try execute("PRAGMA busy_timeout=5000;")
        if mode == .readWriteCreate {
            // Enable WAL mode. Skipped for read-only connections: the journal mode is a
            // property of the database file, and changing it is a write.
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;") // Safe with WAL
        }
        try execute("PRAGMA temp_store=MEMORY;")
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    /// Closes the underlying handle. Safe to call more than once. Statements already
    /// prepared keep working until finalized (`sqlite3_close_v2` defers the real close),
    /// but new `execute`/`prepare` calls throw. Exists so an owner can release the
    /// file — e.g. to let another connection take it exclusively — without waiting for
    /// deinit.
    public func close() {
        queue.sync(flags: .barrier) {
            sqlite3_close_v2(db)
            db = nil
        }
    }

    public func execute(_ sql: String) throws {
        try queue.sync(flags: .barrier) {
            guard db != nil else {
                throw SQLiteError.executeFailed(SQLITE_MISUSE, "connection is closed")
            }
            var errMsg: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if result != SQLITE_OK {
                let msg = errMsg.map { String(cString: $0) }
                sqlite3_free(errMsg)
                throw SQLiteError.executeFailed(result, msg)
            }
        }
    }

    /// Serializes whole transactions: SQLite transactions are per-connection, so two
    /// threads interleaving BEGIN…COMMIT here would share one transaction — the
    /// second BEGIN fails, and its ROLLBACK would silently discard the first thread's
    /// staged writes while that thread's remaining statements auto-commit one by one.
    /// Recursive so a nested `transaction` on the same thread fails at BEGIN (as it
    /// always has) instead of deadlocking.
    ///
    /// Scope: this serializes `transaction` blocks against each other. A bare
    /// `execute`/`prepare` issued from another thread while a transaction is open
    /// still joins it (standard shared-connection SQLite semantics) — keep ad-hoc
    /// statements off a connection whose transactions must be isolated.
    private let transactionLock = NSRecursiveLock()

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        transactionLock.lock()
        defer { transactionLock.unlock() }
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
            guard db != nil else {
                throw SQLiteError.prepareFailed(SQLITE_MISUSE, "connection is closed")
            }
            var stmt: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard result == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.prepareFailed(result, msg)
            }
            return SQLiteStatement(stmt: stmt, db: db)
        }
    }
    
    public var userVersion: Int32 {
        get {
            guard let stmt = try? prepare("PRAGMA user_version;") else { return 0 }
            defer { stmt.reset() }
            if (try? stmt.step()) == true {
                return Int32(stmt.columnInt(at: 0))
            }
            return 0
        }
        set {
            try? execute("PRAGMA user_version = \(newValue);")
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
