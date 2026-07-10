import os

/// Loggers for the library's runtime diagnostics. Everything DProvenanceKit reports at
/// runtime goes through `os.Logger` under the `com.dprovenancekit` subsystem — never
/// `print` — so host applications can filter, persist, or silence it with standard
/// unified-logging tooling.
enum DPKLog {
    static let store = Logger(subsystem: "com.dprovenancekit", category: "store")
    static let cloud = Logger(subsystem: "com.dprovenancekit", category: "cloud")
    static let anomaly = Logger(subsystem: "com.dprovenancekit", category: "anomaly")
    static let alignment = Logger(subsystem: "com.dprovenancekit", category: "alignment")
}
