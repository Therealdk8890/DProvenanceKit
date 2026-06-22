import Foundation

public struct AlignmentNarrativeCompiler: Sendable {
    
    public init() {}
    
    public func compile(from findings: [AlignmentFinding]) -> String {
        var paragraphs: [String] = []
        
        let removals = findings.compactMap { finding -> String? in
            if case let .criticalStepRemoved(id) = finding { return id }
            return nil
        }
        
        let additions = findings.compactMap { finding -> String? in
            if case let .criticalStepAdded(id) = finding { return id }
            return nil
        }
        
        let semantics = findings.compactMap { finding -> (String, String)? in
            if case let .semanticEvolution(b, c) = finding { return (b, c) }
            return nil
        }
        
        let reorders = findings.compactMap { finding -> String? in
            if case let .reorderedExecution(id, _, _) = finding { return id }
            return nil
        }
        
        var riskLevel = RegressionRisk.Level.none
        for finding in findings {
            if case let .regressionRisk(risk) = finding {
                riskLevel = risk.level
            }
        }
        
        // Introductory sentence based on severity
        if removals.isEmpty && additions.isEmpty && semantics.isEmpty && reorders.isEmpty {
            paragraphs.append("This trace remained fully stable with no structural deviations.")
        } else if removals.isEmpty && additions.isEmpty {
            paragraphs.append("This trace remained largely stable with some structural or semantic shifts.")
        } else {
            paragraphs.append("This trace experienced significant structural changes.")
        }
        
        // Process removals
        if !removals.isEmpty {
            if removals.count == 1 {
                paragraphs.append("One critical validation step ('\(removals[0])') was removed.")
            } else {
                paragraphs.append("\(removals.count) critical steps were removed (e.g., '\(removals[0])').")
            }
        }
        
        // Process additions
        if !additions.isEmpty {
            if additions.count == 1 {
                paragraphs.append("A new critical step ('\(additions[0])') was introduced.")
            } else {
                paragraphs.append("\(additions.count) new critical steps were introduced.")
            }
        }
        
        // Process semantics
        if !semantics.isEmpty {
            for (b, c) in semantics {
                paragraphs.append("The retrieval phase changed from '\(b)' to '\(c)' and was accepted as a semantic match.")
            }
        }
        
        // Process reorders
        if !reorders.isEmpty {
            paragraphs.append("The execution order changed for \(reorders.count) step(s) (e.g., '\(reorders[0])') without altering overall trace structure.")
        }
        
        // Conclusion
        paragraphs.append("Overall regression risk: \(riskLevel.rawValue.capitalized).")
        
        return paragraphs.joined(separator: "\n\n")
    }
}
