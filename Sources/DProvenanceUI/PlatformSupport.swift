#if !os(macOS)
public enum DProvenanceUIPlatformSupport {
    public static let isAvailable = false
    public static let message = "DProvenanceUI is macOS-only. Use DProvenanceKit for shared tracing on this platform."
}
#endif
