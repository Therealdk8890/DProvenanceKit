import Foundation
import XCTest
@testable import DProvenanceKit

final class StructuralAlignmentEngineV1Tests: XCTestCase {
    private struct VectorDocument: Decodable {
        let cases: [VectorCase]
    }

    private struct VectorCase: Decodable {
        let id: String
        let target: [StructuralAlignmentNodeV1]
        let candidate: [StructuralAlignmentNodeV1]
        let configuration: CaseConfiguration?
        let expected: ExpectedResult
    }

    private struct CaseConfiguration: Decodable {
        struct Weights: Decodable {
            let type: Double
            let hierarchy: Double
            let payload: Double
        }
        let weights: Weights?
        let minNodeConformance: Double?
        let minGlobalF1Floor: Double?

        enum CodingKeys: String, CodingKey {
            case weights
            case minNodeConformance = "min_node_conformance"
            case minGlobalF1Floor = "min_global_f1_floor"
        }
    }

    private struct ExpectedResult: Decodable {
        let tp: Int
        let fp: Int
        let fn: Int
        let globalF1: Double
        let conforming: Bool
        let hierarchyGatePassed: Bool
        let orderGatePassed: Bool
        let f1GatePassed: Bool
        let emptyInput: Bool
        let allRequiredNodesMeetScoreThreshold: Bool
        let verdicts: [ExpectedVerdict]

        enum CodingKeys: String, CodingKey {
            case tp, fp, fn, conforming, verdicts
            case globalF1 = "global_f1"
            case hierarchyGatePassed = "hierarchy_gate_passed"
            case orderGatePassed = "order_gate_passed"
            case f1GatePassed = "f1_gate_passed"
            case emptyInput = "empty_input"
            case allRequiredNodesMeetScoreThreshold = "all_required_nodes_meet_score_threshold"
        }
    }

    private struct ExpectedVerdict: Decodable {
        let targetID: String
        let candidateID: String?
        let suggestedCandidateID: String?
        let typeScore: Double
        let hierarchyScore: Double
        let payloadScore: Double
        let nodeScore: Double
        let matched: Bool
        let gatePassed: Bool
        let reason: String

        enum CodingKeys: String, CodingKey {
            case matched, reason
            case targetID = "target_id"
            case candidateID = "candidate_id"
            case suggestedCandidateID = "suggested_candidate_id"
            case typeScore = "type_score"
            case hierarchyScore = "hierarchy_score"
            case payloadScore = "payload_score"
            case nodeScore = "node_score"
            case gatePassed = "gate_passed"
        }
    }

    private func loadVectors() throws -> VectorDocument {
        let source = URL(fileURLWithPath: #filePath)
        let repositoryRoot = source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("ConformanceHarness")
            .appendingPathComponent("vectors")
            .appendingPathComponent("structural_alignment_v1.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VectorDocument.self, from: data)
    }

    private func engine(for testCase: VectorCase) throws -> StructuralAlignmentEngineV1 {
        let weights = testCase.configuration?.weights
        let configuration = try StructuralAlignmentConfigurationV1(
            typeWeight: (weights?.type ?? 5000) / 10_000,
            hierarchyWeight: (weights?.hierarchy ?? 3000) / 10_000,
            payloadWeight: (weights?.payload ?? 2000) / 10_000,
            minNodeConformance: (testCase.configuration?.minNodeConformance ?? 8000) / 10_000,
            minGlobalF1Floor: (testCase.configuration?.minGlobalF1Floor ?? 9500) / 10_000
        )
        return StructuralAlignmentEngineV1(configuration: configuration)
    }

    func testProductionEngineReproducesSharedStructuralAlignmentVectors() throws {
        let document = try loadVectors()
        for testCase in document.cases {
            let result = try engine(for: testCase).align(
                target: testCase.target,
                candidate: testCase.candidate
            )
            let expected = testCase.expected
            XCTAssertEqual(result.tp, expected.tp, testCase.id)
            XCTAssertEqual(result.fp, expected.fp, testCase.id)
            XCTAssertEqual(result.fn, expected.fn, testCase.id)
            XCTAssertEqual(result.globalF1, expected.globalF1, accuracy: 1e-12, testCase.id)
            XCTAssertEqual(result.conforming, expected.conforming, testCase.id)
            XCTAssertEqual(result.hierarchyGatePassed, expected.hierarchyGatePassed, testCase.id)
            XCTAssertEqual(result.orderGatePassed, expected.orderGatePassed, testCase.id)
            XCTAssertEqual(result.f1GatePassed, expected.f1GatePassed, testCase.id)
            XCTAssertEqual(result.emptyInput, expected.emptyInput, testCase.id)
            XCTAssertEqual(
                result.allRequiredNodesMeetScoreThreshold,
                expected.allRequiredNodesMeetScoreThreshold,
                testCase.id
            )

            let actualByTarget = Dictionary(
                uniqueKeysWithValues: result.verdicts.map { ($0.targetID, $0) }
            )
            XCTAssertEqual(actualByTarget.count, expected.verdicts.count, testCase.id)
            XCTAssertEqual(
                Set(actualByTarget.keys),
                Set(expected.verdicts.map(\.targetID)),
                testCase.id
            )
            for expectedVerdict in expected.verdicts {
                guard let actual = actualByTarget[expectedVerdict.targetID] else {
                    XCTFail("\(testCase.id): missing verdict for \(expectedVerdict.targetID)")
                    continue
                }
                XCTAssertEqual(actual.candidateID, expectedVerdict.candidateID, testCase.id)
                XCTAssertEqual(
                    actual.suggestedCandidateID,
                    expectedVerdict.suggestedCandidateID,
                    testCase.id
                )
                XCTAssertEqual(actual.matched, expectedVerdict.matched, testCase.id)
                XCTAssertEqual(actual.gatePassed, expectedVerdict.gatePassed, testCase.id)
                XCTAssertEqual(actual.reason, expectedVerdict.reason, testCase.id)
                XCTAssertEqual(actual.typeScore, expectedVerdict.typeScore, accuracy: 1e-12, testCase.id)
                XCTAssertEqual(actual.hierarchyScore, expectedVerdict.hierarchyScore, accuracy: 1e-12, testCase.id)
                XCTAssertEqual(actual.payloadScore, expectedVerdict.payloadScore, accuracy: 1e-12, testCase.id)
                XCTAssertEqual(actual.nodeScore, expectedVerdict.nodeScore, accuracy: 1e-12, testCase.id)
            }
        }
    }

    func testInvalidParentGraphIsRejected() throws {
        let engine = StructuralAlignmentEngineV1(
            configuration: try StructuralAlignmentConfigurationV1()
        )
        let cycle = [
            StructuralAlignmentNodeV1(
                id: "a", parentID: "b", type: "A", payloadSignature: "a"
            ),
            StructuralAlignmentNodeV1(
                id: "b", parentID: "a", type: "B", payloadSignature: "b"
            )
        ]
        XCTAssertThrowsError(try engine.align(target: cycle, candidate: []))
    }

    func testInvalidWeightsAreRejected() {
        XCTAssertThrowsError(
            try StructuralAlignmentConfigurationV1(
                typeWeight: 0.5,
                hierarchyWeight: 0.2,
                payloadWeight: 0.2
            )
        )
    }

    func testConfigurationRejectsSubBasisPointPrecision() {
        XCTAssertThrowsError(
            try StructuralAlignmentConfigurationV1(minNodeConformance: 0.80001)
        )
    }

    func testEngineRemainsSeparateFromLegacyMatcher() {
        XCTAssertEqual(StructuralAlignmentEngineV1.version, "structural-alignment-v1")
    }
}
