import Foundation

/// Compressed-row candidate table produced by `DefaultTraceMatcher` during its scoring scan:
/// for base row `i`, the entries `rowStart[i]..<rowStart[i + 1]` are the comparison indices
/// (ascending) whose score cleared that base event's ambiguity threshold, alongside the score
/// the matcher computed for the pair.
///
/// The interpreter's ambiguity rebuild consumes this instead of re-scoring every
/// base × comparison pair. The reuse is exact by construction: the matcher's per-base gate
/// (`score >= equivalenceEvaluator.ambiguityThreshold(for: baseEvent.payload)`) is the same
/// gate the rebuild applied when it re-scored, and the score is the same function of the
/// same pair.
internal struct AlignmentCandidateIndex: Sendable {
    /// Comparison-array indices of qualifying candidates, grouped by base row.
    var compIndices: [Int] = []
    /// `scores[k]` is the match score for the pair behind `compIndices[k]`.
    var scores: [Double] = []
    /// Row offsets into `compIndices`/`scores`; always `base.count + 1` entries once built.
    var rowStart: [Int] = []
}
