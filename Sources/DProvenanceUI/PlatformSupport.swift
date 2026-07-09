public enum DProvenanceUIPlatformSupport {
    public static let isAvailable = true

    #if canImport(AppKit)
    public static let hasNativeDatabasePicker = true
    public static let message = "DProvenanceUI is available with the built-in macOS database picker."
    #else
    public static let hasNativeDatabasePicker = false
    public static let message = "DProvenanceUI is available. Host apps provide a trace database URL with StoreManager.loadDatabase(at:)."
    #endif
}
