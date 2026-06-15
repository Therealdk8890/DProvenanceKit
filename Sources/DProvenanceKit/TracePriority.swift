import Foundation

/// Priority tiers for trace events to determine congestion control and sampling behavior under extreme load.
public enum TracePriority: Int, Sendable, Comparable, Codable {
    /// Purely quantitative/high-frequency signals (e.g. intermediate token counts, debug stats).
    /// MUST NEVER affect reasoning correctness or diff results. Easily dropped under load.
    case telemetry = 0
    
    /// Qualitative debugging state. Useful for debugging but not strictly necessary for logical verification.
    case diagnostic = 1
    
    /// Execution logic integrity. Essential for preserving logical structure and sequence.
    /// Capped per run under extreme load but preserved globally if possible.
    case structural = 2
    
    /// Replay correctness boundary. Crucial for replay integrity and anomaly detection.
    /// NEVER dropped (e.g. start, end, error).
    case critical = 3
    
    public static func < (lhs: TracePriority, rhs: TracePriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
