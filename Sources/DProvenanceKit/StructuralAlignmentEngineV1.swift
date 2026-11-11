import Foundation

/// Input and configuration failures for the experimental Structural Alignment v1 engine.
public enum StructuralAlignmentErrorV1: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidNode(String)
    case duplicateID(String)
    case missingParent(nodeID: String, parentID: String)
    case parentCycle(String)
}

/// Language-neutral scoring configuration for Structural Alignment v1.
public struct StructuralAlignmentConfigurationV1: Sendable, Equatable {
    public let typeWeight: Double
    public let hierarchyWeight: Double
    public let payloadWeight: Double
    public let minNodeConformance: Double
    public let minGlobalF1Floor: Double
    fileprivate let typeWeightBPS: Int
    fileprivate let hierarchyWeightBPS: Int
    fileprivate let payloadWeightBPS: Int
    fileprivate let minNodeConformanceBPS: Int
    fileprivate let minGlobalF1FloorBPS: Int

    public init(
        typeWeight: Double = 0.5,
        hierarchyWeight: Double = 0.3,
        payloadWeight: Double = 0.2,
        minNodeConformance: Double = 0.8,
        minGlobalF1Floor: Double = 0.95
    ) throws {
        func basisPoints(_ value: Double, name: String) throws -> Int {
            guard value.isFinite, (0.0...1.0).contains(value),
                  let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
                throw StructuralAlignmentErrorV1.invalidConfiguration(
                    "\(name) must be finite and in [0, 1]"
                )
            }
            let scaled = decimal * Decimal(10_000)
            var rounded = Decimal()
            var copy = scaled
            NSDecimalRound(&rounded, &copy, 0, .plain)
            guard scaled == rounded else {
                throw StructuralAlignmentErrorV1.invalidConfiguration(
                    "\(name) must be exactly representable in basis points"
                )
            }
            return NSDecimalNumber(decimal: rounded).intValue
        }

        let typeBPS = try basisPoints(typeWeight, name: "typeWeight")
        let hierarchyBPS = try basisPoints(hierarchyWeight, name: "hierarchyWeight")
        let payloadBPS = try basisPoints(payloadWeight, name: "payloadWeight")
        let nodeThresholdBPS = try basisPoints(minNodeConformance, name: "minNodeConformance")
        let globalFloorBPS = try basisPoints(minGlobalF1Floor, name: "minGlobalF1Floor")
        guard typeBPS + hierarchyBPS + payloadBPS == 10_000 else {
            throw StructuralAlignmentErrorV1.invalidConfiguration(
                "component weights must sum to 10000 basis points"
            )
        }
        self.typeWeight = typeWeight
        self.hierarchyWeight = hierarchyWeight
        self.payloadWeight = payloadWeight
        self.minNodeConformance = minNodeConformance
        self.minGlobalF1Floor = minGlobalF1Floor
        self.typeWeightBPS = typeBPS
        self.hierarchyWeightBPS = hierarchyBPS
        self.payloadWeightBPS = payloadBPS
        self.minNodeConformanceBPS = nodeThresholdBPS
        self.minGlobalF1FloorBPS = globalFloorBPS
    }
}

/// One recorded event in a structural trace. Array position is its sequence number.
public struct StructuralAlignmentNodeV1: Codable, Sendable, Equatable {
    public let id: String
    public let parentID: String?
    public let type: String
    public let payloadSignature: String

    public init(id: String, parentID: String?, type: String, payloadSignature: String) {
        self.id = id
        self.parentID = parentID
        self.type = type
        self.payloadSignature = payloadSignature
    }

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case type
        case payloadSignature = "payload_signature"
    }
}

/// Per-target-node result. A suggestion is diagnostic only and never counts as a match.
public struct StructuralNodeVerdictV1: Sendable, Equatable {
    public let targetID: String
    public let candidateID: String?
    public let suggestedCandidateID: String?
    public let typeScore: Double
    public let hierarchyScore: Double
    public let payloadScore: Double
    public let nodeScore: Double
    public let matched: Bool
    public let gatePassed: Bool
    public let reason: String
}

/// Aggregate Structural Alignment v1 result.
public struct StructuralAlignmentResultV1: Sendable, Equatable {
    public let tp: Int
    public let fp: Int
    public let fn: Int
    public let globalF1: Double
    public let hierarchyGatePassed: Bool
    public let orderGatePassed: Bool
    public let allRequiredNodesMeetScoreThreshold: Bool
    public let f1GatePassed: Bool
    public let emptyInput: Bool
    public let conforming: Bool
    public let verdicts: [StructuralNodeVerdictV1]
}

private struct StructuralScoredPairV1 {
    let targetIndex: Int
    let candidateIndex: Int
    let typeScore: Int
    let hierarchyScore: Int
    let payloadScore: Int
    let score: Int
}

/// Parent-first deterministic greedy structural matcher.
///
/// This is intentionally separate from TraceAlignmentEngine and does not alter legacy
/// matching, profile hashes, or Trace Specification v1 behavior.
public struct StructuralAlignmentEngineV1: Sendable {
    public static let version = "structural-alignment-v1"
    public let configuration: StructuralAlignmentConfigurationV1

    public init(configuration: StructuralAlignmentConfigurationV1) {
        self.configuration = configuration
    }

    private func validatedDepths(
        for nodes: [StructuralAlignmentNodeV1],
        side: String
    ) throws -> [Int] {
        var indexByID: [String: Int] = [:]
        for (index, node) in nodes.enumerated() {
            guard !node.id.isEmpty else {
                throw StructuralAlignmentErrorV1.invalidNode("\(side)[\(index)] has an empty id")
            }
            guard indexByID[node.id] == nil else {
                throw StructuralAlignmentErrorV1.duplicateID("\(side) node id \(node.id)")
            }
            indexByID[node.id] = index
        }
        for node in nodes {
            if let parentID = node.parentID, indexByID[parentID] == nil {
                throw StructuralAlignmentErrorV1.missingParent(
                    nodeID: node.id,
                    parentID: parentID
                )
            }
        }

        var depths = [Int?](repeating: nil, count: nodes.count)
        var visiting = Set<String>()
        func depth(at index: Int) throws -> Int {
            if let known = depths[index] { return known }
            let node = nodes[index]
            guard !visiting.contains(node.id) else {
                throw StructuralAlignmentErrorV1.parentCycle(node.id)
            }
            visiting.insert(node.id)
            let value: Int
            if let parentID = node.parentID, let parentIndex = indexByID[parentID] {
                value = try depth(at: parentIndex) + 1
            } else {
                value = 0
            }
            visiting.remove(node.id)
            depths[index] = value
            return value
        }
        for index in nodes.indices {
            _ = try depth(at: index)
        }
        return depths.map { $0 ?? 0 }
    }

    private func score(
        target: StructuralAlignmentNodeV1,
        candidate: StructuralAlignmentNodeV1,
        mappedParents: [String: String]
    ) -> (type: Int, hierarchy: Int, payload: Int, score: Int) {
        let typeScore = target.type == candidate.type ? 1 : 0
        let payloadScore = target.payloadSignature == candidate.payloadSignature ? 1 : 0
        let hierarchyScore: Int
        if let targetParent = target.parentID {
            if let mappedParent = mappedParents[targetParent] {
                hierarchyScore = candidate.parentID == mappedParent ? 1 : 0
            } else {
                hierarchyScore = 0
            }
        } else {
            hierarchyScore = candidate.parentID == nil ? 1 : 0
        }
        let weighted = configuration.typeWeightBPS * typeScore
            + configuration.hierarchyWeightBPS * hierarchyScore
            + configuration.payloadWeightBPS * payloadScore
        return (typeScore, hierarchyScore, payloadScore, weighted)
    }

    public func align(
        target: [StructuralAlignmentNodeV1],
        candidate: [StructuralAlignmentNodeV1]
    ) throws -> StructuralAlignmentResultV1 {
        let targetDepths = try validatedDepths(for: target, side: "target")
        _ = try validatedDepths(for: candidate, side: "candidate")

        var mappedTargetToCandidate: [String: String] = [:]
        var mappedPairs: [Int: StructuralScoredPairV1] = [:]
        var assignedCandidates = Set<Int>()

        for currentDepth in Set(targetDepths).sorted() {
            let depthTargets = target.indices.filter { targetDepths[$0] == currentDepth }
            let availableCandidates = candidate.indices.filter {
                !assignedCandidates.contains($0)
            }
            var eligible: [StructuralScoredPairV1] = []
            for targetIndex in depthTargets {
                for candidateIndex in availableCandidates {
                    let components = score(
                        target: target[targetIndex],
                        candidate: candidate[candidateIndex],
                        mappedParents: mappedTargetToCandidate
                    )
                    if components.score >= configuration.minNodeConformanceBPS {
                        eligible.append(
                            StructuralScoredPairV1(
                                targetIndex: targetIndex,
                                candidateIndex: candidateIndex,
                                typeScore: components.type,
                                hierarchyScore: components.hierarchy,
                                payloadScore: components.payload,
                                score: components.score
                            )
                        )
                    }
                }
            }
            eligible.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.candidateIndex != rhs.candidateIndex {
                    return lhs.candidateIndex < rhs.candidateIndex
                }
                let leftCandidateID = candidate[lhs.candidateIndex].id
                let rightCandidateID = candidate[rhs.candidateIndex].id
                if leftCandidateID != rightCandidateID {
                    return leftCandidateID < rightCandidateID
                }
                if lhs.targetIndex != rhs.targetIndex {
                    return lhs.targetIndex < rhs.targetIndex
                }
                return target[lhs.targetIndex].id < target[rhs.targetIndex].id
            }

            var assignedTargets = Set<Int>()
            for pair in eligible {
                guard !assignedTargets.contains(pair.targetIndex),
                      !assignedCandidates.contains(pair.candidateIndex) else {
                    continue
                }
                assignedTargets.insert(pair.targetIndex)
                assignedCandidates.insert(pair.candidateIndex)
                mappedTargetToCandidate[target[pair.targetIndex].id] =
                    candidate[pair.candidateIndex].id
                mappedPairs[pair.targetIndex] = pair
            }
        }

        // Suggestions are post-assignment diagnostics; zero-score candidates are not useful.
        var suggestions: [Int: StructuralScoredPairV1] = [:]
        for targetIndex in target.indices where mappedPairs[targetIndex] == nil {
            var ranked: [StructuralScoredPairV1] = []
            for candidateIndex in candidate.indices where !assignedCandidates.contains(candidateIndex) {
                let components = score(
                    target: target[targetIndex],
                    candidate: candidate[candidateIndex],
                    mappedParents: mappedTargetToCandidate
                )
                guard components.score > .zero else { continue }
                ranked.append(
                    StructuralScoredPairV1(
                        targetIndex: targetIndex,
                        candidateIndex: candidateIndex,
                        typeScore: components.type,
                        hierarchyScore: components.hierarchy,
                        payloadScore: components.payload,
                        score: components.score
                    )
                )
            }
            ranked.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.candidateIndex != rhs.candidateIndex {
                    return lhs.candidateIndex < rhs.candidateIndex
                }
                return candidate[lhs.candidateIndex].id < candidate[rhs.candidateIndex].id
            }
            if let best = ranked.first { suggestions[targetIndex] = best }
        }

        var reordered = Set<Int>()
        let matchedTargetIndices = mappedPairs.keys.sorted()
        for leftOffset in matchedTargetIndices.indices {
            let leftTargetIndex = matchedTargetIndices[leftOffset]
            guard let leftPair = mappedPairs[leftTargetIndex] else { continue }
            for rightTargetIndex in matchedTargetIndices.dropFirst(leftOffset + 1) {
                guard let rightPair = mappedPairs[rightTargetIndex] else { continue }
                if leftPair.candidateIndex > rightPair.candidateIndex {
                    reordered.insert(leftTargetIndex)
                    reordered.insert(rightTargetIndex)
                }
            }
        }

        let verdicts = target.indices.map { targetIndex -> StructuralNodeVerdictV1 in
            if let pair = mappedPairs[targetIndex] {
                let hierarchyPass = pair.hierarchyScore == 1
                let orderPass = !reordered.contains(targetIndex)
                let reason = !hierarchyPass
                    ? "PARENT_HIERARCHY_MISMATCH"
                    : (!orderPass ? "REORDERED_REQUIRED_EVENTS" : "CONFORMANT")
                return StructuralNodeVerdictV1(
                    targetID: target[targetIndex].id,
                    candidateID: candidate[pair.candidateIndex].id,
                    suggestedCandidateID: nil,
                    typeScore: Double(pair.typeScore),
                    hierarchyScore: Double(pair.hierarchyScore),
                    payloadScore: Double(pair.payloadScore),
                    nodeScore: Double(pair.score) / 10_000,
                    matched: true,
                    gatePassed: hierarchyPass && orderPass,
                    reason: reason
                )
            }
            if let suggestion = suggestions[targetIndex] {
                let reason = suggestion.hierarchyScore == 0
                    ? "PARENT_HIERARCHY_MISMATCH"
                    : "NODE_SCORE_BELOW_THRESHOLD"
                return StructuralNodeVerdictV1(
                    targetID: target[targetIndex].id,
                    candidateID: nil,
                    suggestedCandidateID: candidate[suggestion.candidateIndex].id,
                    typeScore: Double(suggestion.typeScore),
                    hierarchyScore: Double(suggestion.hierarchyScore),
                    payloadScore: Double(suggestion.payloadScore),
                    nodeScore: Double(suggestion.score) / 10_000,
                    matched: false,
                    gatePassed: false,
                    reason: reason
                )
            }
            return StructuralNodeVerdictV1(
                targetID: target[targetIndex].id,
                candidateID: nil,
                suggestedCandidateID: nil,
                typeScore: 0,
                hierarchyScore: 0,
                payloadScore: 0,
                nodeScore: 0,
                matched: false,
                gatePassed: false,
                reason: "MISSING_REQUIRED_EVENT"
            )
        }

        let tp = mappedPairs.count
        let fn = target.count - tp
        let fp = candidate.count - assignedCandidates.count
        let denominator = 2 * tp + fp + fn
        let emptyInput = target.isEmpty && candidate.isEmpty
        let f1 = denominator == 0 ? 1.0 : Double(2 * tp) / Double(denominator)
        let f1GatePassed = denominator == 0
            || 2 * tp * 10_000 >= configuration.minGlobalF1FloorBPS * denominator
        let hierarchyGate = mappedPairs.values.allSatisfy { $0.hierarchyScore == 1 }
        let orderGate = reordered.isEmpty
        let allNodesMapped = tp == target.count
        let conforming = !emptyInput
            && allNodesMapped
            && f1GatePassed
            && hierarchyGate
            && orderGate

        return StructuralAlignmentResultV1(
            tp: tp,
            fp: fp,
            fn: fn,
            globalF1: f1,
            hierarchyGatePassed: hierarchyGate,
            orderGatePassed: orderGate,
            allRequiredNodesMeetScoreThreshold: allNodesMapped,
            f1GatePassed: f1GatePassed,
            emptyInput: emptyInput,
            conforming: conforming,
            verdicts: verdicts
        )
    }
}
