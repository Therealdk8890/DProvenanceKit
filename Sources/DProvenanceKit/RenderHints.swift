import Foundation

public enum DiffPresentationMode: Sendable, Equatable {
    case none
    case singleSnapshot
    case comparison
}

public struct RenderHints: Sendable, Equatable {
    public let collapsedByDefault: Set<String>
    public let importantEventTypes: Set<String>
    public let highlightQuarantine: Bool
    public let diffMode: DiffPresentationMode
    
    public init(
        collapsedByDefault: Set<String> = [],
        importantEventTypes: Set<String> = [],
        highlightQuarantine: Bool = true,
        diffMode: DiffPresentationMode = .none
    ) {
        self.collapsedByDefault = collapsedByDefault
        self.importantEventTypes = importantEventTypes
        self.highlightQuarantine = highlightQuarantine
        self.diffMode = diffMode
    }
}
