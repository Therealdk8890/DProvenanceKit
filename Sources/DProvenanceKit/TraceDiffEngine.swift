import Foundation

public struct TraceDiffResult: Sendable, Equatable {
    public enum ChangeKind: Sendable, Equatable {
        case added
        case removed
    }
    
    public struct Change: Sendable, Equatable {
        public let kind: ChangeKind
        /// The original sequence ID of the event before any filtering or normalization occurred
        public let originalSequence: UInt64
        /// The event type identifier that was added or removed
        public let typeIdentifier: String
        /// The engine context where the change occurred
        public let engineName: String
    }
    
    public let baseRunID: UUID
    public let comparisonRunID: UUID
    public let changes: [Change]
    
    public var isIdentical: Bool { changes.isEmpty }
}

public struct TraceDiffEngine<T: TraceableEvent>: Sendable {
    
    private struct DiffElement: Hashable {
        let signature: String
        let sequence: UInt64
        let typeIdentifier: String
        let engineName: String
        
        static func == (lhs: DiffElement, rhs: DiffElement) -> Bool {
            lhs.signature == rhs.signature
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(signature)
        }
    }
    
    public init() {}
    
    public func diff(
        base: TraceRun<T>, 
        comparison: TraceRun<T>, 
        minimumPriority: TracePriority = .structural
    ) -> TraceDiffResult {
        // 1. Normalize and extract structural signatures
        let baseElements = base.events
            .filter { $0.payload.priority >= minimumPriority }
            .map { DiffElement(
                signature: "\($0.payload.typeIdentifier)::\($0.engineName)",
                sequence: $0.sequence,
                typeIdentifier: $0.payload.typeIdentifier,
                engineName: $0.engineName
            )}
            
        let compElements = comparison.events
            .filter { $0.payload.priority >= minimumPriority }
            .map { DiffElement(
                signature: "\($0.payload.typeIdentifier)::\($0.engineName)",
                sequence: $0.sequence,
                typeIdentifier: $0.payload.typeIdentifier,
                engineName: $0.engineName
            )}
        
        // 2. Perform native Collection diff on causal signatures
        let difference = compElements.difference(from: baseElements)
        
        // 3. Map to domain model with true original indexes
        var mappedChanges: [TraceDiffResult.Change] = []
        for change in difference {
            switch change {
            case .insert(let offset, let element, _):
                mappedChanges.append(.init(
                    kind: .added, 
                    originalSequence: element.sequence, 
                    typeIdentifier: element.typeIdentifier,
                    engineName: element.engineName
                ))
            case .remove(let offset, let element, _):
                mappedChanges.append(.init(
                    kind: .removed, 
                    originalSequence: element.sequence, 
                    typeIdentifier: element.typeIdentifier,
                    engineName: element.engineName
                ))
            }
        }
        
        return TraceDiffResult(
            baseRunID: base.runID,
            comparisonRunID: comparison.runID,
            changes: mappedChanges
        )
    }
}
