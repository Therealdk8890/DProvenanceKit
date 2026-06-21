import Foundation
@testable import DProvenanceKit

let runID = UUID()
let spanA = "spanA"

enum MockEvent: TraceableEvent, Equatable {
    case start
    case middle(String)
    case end
    
    var typeIdentifier: String {
        switch self {
        case .start: return "start"
        case .middle: return "middle"
        case .end: return "end"
        }
    }
    var priority: TracePriority { .structural }
}

let e1 = TraceEvent<MockEvent>(id: UUID(), runID: runID, contextID: "test", engineName: "test", schemaVersion: 1, sequence: 1, spanID: spanA, parentSpanID: nil, payload: .start)
let e2 = TraceEvent<MockEvent>(id: UUID(), runID: runID, contextID: "test", engineName: "test", schemaVersion: 1, sequence: 2, spanID: spanA, parentSpanID: nil, payload: .end)

let baseSnapshot = TraceReplayEngine(committed: [e1, e2]).snapshot()
let compSnapshot = TraceReplayEngine(committed: [e1], quarantined: [e2]).snapshot()

print("base roots:", baseSnapshot.roots.map { $0.spanID })
print("base contam:", baseSnapshot.roots.first?.containsQuarantinedEvents)
print("comp roots:", compSnapshot.roots.map { $0.spanID })
print("comp contam:", compSnapshot.roots.first?.containsQuarantinedEvents)

let diff = SnapshotDiffEngine<MockEvent>().diff(base: baseSnapshot, comparison: compSnapshot)
print("spanChanges:", diff.spanChanges)
