import Foundation

public enum SpanChange: Sendable, Equatable {
    case added(spanID: String?, parentSpanID: String?)
    case removed(spanID: String?, parentSpanID: String?)
    case reparented(spanID: String?, fromParent: String?, toParent: String?)
    case contaminationChanged(spanID: String?, from: Bool, to: Bool)
}

public enum EventChange<T: TraceableEvent>: Sendable, Equatable {
    case added(event: ReplayEvent<T>, spanID: String?)
    case removed(event: ReplayEvent<T>, spanID: String?)
    case modified(before: ReplayEvent<T>, after: ReplayEvent<T>, spanID: String?)
}

/// Represents the point where two trace timelines diverge.
/// `divergenceSequence` explicitly represents the sequence of the *first differing event*.
public struct DivergencePoint<T: TraceableEvent>: Sendable, Equatable {
    public let spanID: String?
    public let commonPrefixLength: Int
    public let divergenceSequence: UInt64
    public let leftEvent: ReplayEvent<T>?
    public let rightEvent: ReplayEvent<T>?
    
    public init(spanID: String?, commonPrefixLength: Int, divergenceSequence: UInt64, leftEvent: ReplayEvent<T>?, rightEvent: ReplayEvent<T>?) {
        self.spanID = spanID
        self.commonPrefixLength = commonPrefixLength
        self.divergenceSequence = divergenceSequence
        self.leftEvent = leftEvent
        self.rightEvent = rightEvent
    }
}

public struct DiffSummary: Sendable, Equatable {
    public let addedSpans: Int
    public let removedSpans: Int
    public let addedEvents: Int
    public let removedEvents: Int
    public let modifiedEvents: Int
    public let contaminatedSpans: Int
    public let divergencePoints: Int
    
    public init(
        addedSpans: Int,
        removedSpans: Int,
        addedEvents: Int,
        removedEvents: Int,
        modifiedEvents: Int,
        contaminatedSpans: Int,
        divergencePoints: Int
    ) {
        self.addedSpans = addedSpans
        self.removedSpans = removedSpans
        self.addedEvents = addedEvents
        self.removedEvents = removedEvents
        self.modifiedEvents = modifiedEvents
        self.contaminatedSpans = contaminatedSpans
        self.divergencePoints = divergencePoints
    }
}

public struct SnapshotDiffResult<T: TraceableEvent>: Sendable, Equatable {
    public let spanChanges: [SpanChange]
    public let eventChanges: [EventChange<T>]
    public let divergences: [DivergencePoint<T>]
    
    public init(
        spanChanges: [SpanChange],
        eventChanges: [EventChange<T>],
        divergences: [DivergencePoint<T>]
    ) {
        self.spanChanges = spanChanges
        self.eventChanges = eventChanges
        self.divergences = divergences
    }
    
    public var summary: DiffSummary {
        var addedSpans = 0
        var removedSpans = 0
        var contaminationChangedSpans = 0
        
        for sc in spanChanges {
            switch sc {
            case .added: addedSpans += 1
            case .removed: removedSpans += 1
            case .contaminationChanged: contaminationChangedSpans += 1
            case .reparented: break
            }
        }
        
        var addedEvents = 0
        var removedEvents = 0
        var modifiedEvents = 0
        
        for ec in eventChanges {
            switch ec {
            case .added: addedEvents += 1
            case .removed: removedEvents += 1
            case .modified: modifiedEvents += 1
            }
        }
        
        return DiffSummary(
            addedSpans: addedSpans,
            removedSpans: removedSpans,
            addedEvents: addedEvents,
            removedEvents: removedEvents,
            modifiedEvents: modifiedEvents,
            contaminatedSpans: contaminationChangedSpans,
            divergencePoints: divergences.count
        )
    }
    
    public var isIdentical: Bool {
        spanChanges.isEmpty && eventChanges.isEmpty && divergences.isEmpty
    }
}
