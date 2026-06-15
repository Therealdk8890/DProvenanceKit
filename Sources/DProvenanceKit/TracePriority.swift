import Foundation

/// Priority tiers for trace events to determine congestion control and sampling behavior under extreme load.
public enum TracePriority: Int, Sendable, Comparable {
    /// High-volume logging, easily dropped under load (e.g. intermediate token counts, debug stats)
    case verbose = 0
    
    /// Useful for debugging but not strictly necessary for logical verification (e.g. state diffs)
    case diagnostic = 1
    
    /// Essential for preserving logical structure and sequence, capped per run under extreme load but preserved if possible
    case structural = 2
    
    /// Crucial for replay integrity and anomaly detection, NEVER dropped (e.g. start, end, error)
    case critical = 3
    
    public static func < (lhs: TracePriority, rhs: TracePriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
