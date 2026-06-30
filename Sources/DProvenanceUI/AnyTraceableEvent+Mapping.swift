#if os(macOS)
import Foundation
import DProvenanceKit

extension RawTraceEvent {
    public func toTraceEvent() -> TraceEvent<AnyTraceableEvent> {
        return TraceEvent(
            id: self.id,
            runID: self.runID,
            contextID: self.contextID,
            engineName: self.engineName,
            schemaVersion: 1,
            sequence: self.sequence,
            spanID: self.spanID,
            parentSpanID: self.parentSpanID,
            payload: AnyTraceableEvent(
                typeIdentifier: self.typeIdentifier,
                priorityValue: self.priority,
                rawJSON: self.payloadJSON
            ),
            timestamp: self.timestamp
        )
    }
}
#endif
