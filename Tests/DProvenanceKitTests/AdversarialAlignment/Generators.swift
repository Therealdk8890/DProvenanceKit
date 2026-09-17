import Foundation
@testable import DProvenanceKit

struct AdvEvent: TraceableEvent {
    let kind: String
    let body: String
    let critical: Bool
    let semanticLabel: String

    init(kind: String, body: String = "", critical: Bool = false, semanticLabel: String = "") {
        self.kind = kind
        self.body = body
        self.critical = critical
        self.semanticLabel = semanticLabel
    }

    var typeIdentifier: String { kind }
    var priority: TracePriority { critical ? .critical : .structural }
}

struct AdvCase {
    let name: String
    let category: String
    let base: TraceRun<AdvEvent>
    let comparison: TraceRun<AdvEvent>
    let notes: String

    init(_ name: String, _ category: String, _ base: TraceRun<AdvEvent>, _ comparison: TraceRun<AdvEvent>, notes: String = "") {
        self.name = name
        self.category = category
        self.base = base
        self.comparison = comparison
        self.notes = notes
    }
}

enum AdvGenerators {
    static let specialEvaluatorCases: Set<String> = [
        "greedy_trap_assignment",
        "greedy_trap_3x3",
        "greedy_trap_4x4",
        "greedy_trap_steal_column",
        "semantic_evaluator_disagree",
        "semantic_three_cluster_cross",
        "semantic_partial_cluster",
    ]

    static func mkRun(_ specs: [(UInt64, AdvEvent)], parentSpanID: String? = nil) -> TraceRun<AdvEvent> {
        let rid = UUID()
        let events = specs.map { seq, payload in
            TraceEvent(
                runID: rid,
                contextID: "adv_ctx",
                engineName: "adv",
                schemaVersion: 1,
                sequence: seq,
                spanID: "span-\(seq)",
                parentSpanID: parentSpanID,
                payload: payload,
                timestamp: Date(timeIntervalSince1970: 0)
            )
        }
        return TraceRun(runID: rid, contextID: "adv_ctx", events: events)
    }

    // MARK: - Catalog

    static func allCases() -> [AdvCase] {
        var cases: [AdvCase] = []
        cases.append(duplicateEventTypes())
        cases.append(repeatedToolCalls())
        cases.append(contentsOf: nearIdenticalFamily())
        cases.append(contentsOf: insertDeleteFamily())
        cases.append(contentsOf: reorderFamily())
        cases.append(contentsOf: manyEquallyScored())
        cases.append(contentsOf: oneToManyCollisionFamily())
        cases.append(contentsOf: criticalStructuralPriority())
        cases.append(longRepeatedPatternsN(30, name: "long_repeated_patterns"))
        for n in [50, 100, 150, 200] {
            cases.append(longRepeatedPatternsN(n))
        }
        cases.append(contentsOf: nestedInterleavedDuplicates())
        cases.append(contentsOf: thresholdBoundaryExpanded())
        cases.append(contentsOf: semanticHookFamily())
        cases.append(contentsOf: greedyTrapFamily())
        cases.append(contentsOf: seededFuzzFamilies())

        var seen = Set<String>()
        var unique: [AdvCase] = []
        for c in cases {
            if seen.insert(c.name).inserted { unique.append(c) }
        }
        return unique
    }

    static func duplicateEventTypes() -> AdvCase {
        let base = mkRun([
            (0, AdvEvent(kind: "tool_call", body: "search:q1", critical: true)),
            (1, AdvEvent(kind: "tool_call", body: "search:q2", critical: true)),
            (2, AdvEvent(kind: "tool_call", body: "search:q3", critical: true)),
        ])
        let comp = mkRun([
            (0, AdvEvent(kind: "tool_call", body: "search:q3", critical: true)),
            (1, AdvEvent(kind: "tool_call", body: "search:q1-near", critical: true)),
            (2, AdvEvent(kind: "tool_call", body: "search:q2", critical: true)),
            (3, AdvEvent(kind: "tool_call", body: "search:q1", critical: true)),
        ])
        return AdvCase("duplicate_event_types", "duplicates", base, comp)
    }

    static func repeatedToolCalls() -> AdvCase {
        let base = mkRun((0..<8).map { i in
            (UInt64(i), AdvEvent(kind: "tool_call.start", body: "tool=\(i % 3)", critical: false))
        })
        var specs: [(UInt64, AdvEvent)] = []
        var seq: UInt64 = 0
        for i in 0..<8 {
            if i == 2 || i == 5 {
                specs.append((seq, AdvEvent(kind: "tool_call.start", body: "decoy=\(i)", critical: false)))
                seq += 1
            }
            specs.append((seq, AdvEvent(kind: "tool_call.start", body: "tool=\(i % 3)", critical: false)))
            seq += 1
        }
        return AdvCase("repeated_tool_calls", "duplicates", base, mkRun(specs))
    }

    static func nearIdenticalFamily() -> [AdvCase] {
        var out: [AdvCase] = []
        let base0 = mkRun([
            (0, AdvEvent(kind: "decision", body: "authorize:alice:100", critical: true)),
            (1, AdvEvent(kind: "decision", body: "authorize:bob:50", critical: true)),
        ])
        let comp0 = mkRun([
            (0, AdvEvent(kind: "decision", body: "authorize:alice:100 ", critical: true)),
            (1, AdvEvent(kind: "decision", body: "authorize:bob:50", critical: true)),
            (2, AdvEvent(kind: "decision", body: "authorize:alice:100", critical: true)),
        ])
        out.append(AdvCase("near_identical_payloads", "near_identical", base0, comp0))
        for (suffix, a, b) in [
            ("trailing_tab", "val", "val\t"),
            ("double_space", "a b", "a  b"),
            ("prefix", "id:42", "xid:42"),
        ] {
            let base = mkRun([(0, AdvEvent(kind: "decision", body: a, critical: true))])
            let comp = mkRun([
                (0, AdvEvent(kind: "decision", body: b, critical: true)),
                (1, AdvEvent(kind: "decision", body: a, critical: true)),
            ])
            out.append(AdvCase("near_identical_\(suffix)", "near_identical", base, comp))
        }
        return out
    }

    static func insertDeleteFamily() -> [AdvCase] {
        var out: [AdvCase] = []
        out.append(AdvCase(
            "inserted_decoys", "insert_delete",
            mkRun([
                (0, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                (1, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "log", body: "noise", critical: false)),
                (1, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                (2, AdvEvent(kind: "log", body: "more-noise", critical: false)),
                (3, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
                (4, AdvEvent(kind: "decision", body: "decoy", critical: true)),
            ])
        ))
        out.append(AdvCase(
            "deleted_events", "insert_delete",
            mkRun([
                (0, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                (1, AdvEvent(kind: "validate", body: "perms", critical: true)),
                (2, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                (1, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
            ])
        ))
        let baseBulk = mkRun((0..<5).map { i in (UInt64(i), AdvEvent(kind: "step", body: "s\(i)", critical: true)) })
        var bulk: [(UInt64, AdvEvent)] = []
        var seq: UInt64 = 0
        for i in 0..<5 {
            for _ in 0..<3 {
                bulk.append((seq, AdvEvent(kind: "noise", body: "n\(seq)", critical: false)))
                seq += 1
            }
            bulk.append((seq, AdvEvent(kind: "step", body: "s\(i)", critical: true)))
            seq += 1
        }
        out.append(AdvCase("insert_bulk_noise", "insert_delete", baseBulk, mkRun(bulk)))
        out.append(AdvCase(
            "delete_every_other", "insert_delete",
            mkRun((0..<8).map { i in (UInt64(i), AdvEvent(kind: "step", body: "s\(i)", critical: true)) }),
            mkRun((0..<4).map { i in (UInt64(i), AdvEvent(kind: "step", body: "s\(i * 2)", critical: true)) })
        ))
        return out
    }

    static func reorderFamily() -> [AdvCase] {
        [
            AdvCase(
                "reordered_events", "reorder",
                mkRun([
                    (0, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                    (1, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
                    (2, AdvEvent(kind: "sendEmail", body: "z", critical: true)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
                    (1, AdvEvent(kind: "sendEmail", body: "z", critical: true)),
                    (2, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                ])
            ),
            AdvCase(
                "reorder_full_reverse", "reorder",
                mkRun((0..<6).map { i in (UInt64(i), AdvEvent(kind: "t\(i)", body: "b\(i)", critical: true)) }),
                mkRun((0..<6).map { i in (UInt64(i), AdvEvent(kind: "t\(5 - i)", body: "b\(5 - i)", critical: true)) })
            ),
            {
                var order = Array(0..<8)
                for i in stride(from: 0, to: 7, by: 2) {
                    order.swapAt(i, i + 1)
                }
                return AdvCase(
                    "reorder_adjacent_swaps", "reorder",
                    mkRun((0..<8).map { i in (UInt64(i), AdvEvent(kind: "step", body: "s\(i)", critical: true)) }),
                    mkRun((0..<8).map { i in (UInt64(i), AdvEvent(kind: "step", body: "s\(order[i])", critical: true)) })
                )
            }(),
        ]
    }

    static func manyEquallyScored() -> [AdvCase] {
        var out: [AdvCase] = []
        for (nB, nC) in [(1, 8), (3, 9), (5, 5), (8, 12)] {
            out.append(AdvCase(
                "ties_\(nB)x\(nC)", "ties",
                mkRun((0..<nB).map { i in (UInt64(i), AdvEvent(kind: "fetch", body: "same", critical: false)) }),
                mkRun((0..<nC).map { i in (UInt64(i), AdvEvent(kind: "fetch", body: "same", critical: false)) }),
                notes: "all equal scores"
            ))
        }
        let base = mkRun((0..<4).map { i in (UInt64(i), AdvEvent(kind: "item", body: "exact-\(i)", critical: true)) })
        var comp: [(UInt64, AdvEvent)] = (0..<6).map { i in (UInt64(i), AdvEvent(kind: "item", body: "tie", critical: true)) }
        for i in 0..<4 {
            comp.append((UInt64(6 + i), AdvEvent(kind: "item", body: "exact-\(i)", critical: true)))
        }
        out.append(AdvCase("ties_with_exact_anchors", "ties", base, mkRun(comp)))
        return out
    }

    static func oneToManyCollisionFamily() -> [AdvCase] {
        var out: [AdvCase] = []
        out.append(AdvCase(
            "one_to_many_collisions", "collisions",
            mkRun([
                (0, AdvEvent(kind: "decision", body: "weak-prefer-A", critical: true)),
                (1, AdvEvent(kind: "decision", body: "exact-B", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "decision", body: "exact-B", critical: true)),
                (1, AdvEvent(kind: "decision", body: "weak-prefer-A", critical: true)),
            ])
        ))
        let bodiesB = ["alpha", "beta", "gamma"]
        let bodiesC = ["gamma", "alpha", "beta"]
        out.append(AdvCase(
            "collision_rotate_3", "collisions",
            mkRun((0..<3).map { i in (UInt64(i), AdvEvent(kind: "decision", body: bodiesB[i], critical: true)) }),
            mkRun((0..<3).map { i in (UInt64(i), AdvEvent(kind: "decision", body: bodiesC[i], critical: true)) })
        ))
        out.append(AdvCase(
            "collision_many_to_one", "collisions",
            mkRun([
                (0, AdvEvent(kind: "decision", body: "target", critical: true)),
                (1, AdvEvent(kind: "decision", body: "target-near", critical: true)),
                (2, AdvEvent(kind: "decision", body: "other", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "decision", body: "target", critical: true)),
                (1, AdvEvent(kind: "decision", body: "other", critical: true)),
                (2, AdvEvent(kind: "decision", body: "spare", critical: true)),
            ])
        ))
        let n = 5
        out.append(AdvCase(
            "collision_chain_rotate_5", "collisions",
            mkRun((0..<n).map { i in (UInt64(i), AdvEvent(kind: "chain", body: "b\(i)", critical: true)) }),
            mkRun((0..<n).map { i in (UInt64(i), AdvEvent(kind: "chain", body: "b\((i + 1) % n)", critical: true)) })
        ))
        return out
    }

    static func criticalStructuralPriority() -> [AdvCase] {
        [
            AdvCase(
                "critical_structural_mix", "priority_mix",
                mkRun([
                    (0, AdvEvent(kind: "log", body: "l1", critical: false)),
                    (1, AdvEvent(kind: "authorize", body: "a", critical: true)),
                    (2, AdvEvent(kind: "log", body: "l2", critical: false)),
                    (3, AdvEvent(kind: "finalize", body: "f", critical: true)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "authorize", body: "a", critical: true)),
                    (1, AdvEvent(kind: "log", body: "l2", critical: false)),
                    (2, AdvEvent(kind: "finalize", body: "f", critical: true)),
                    (3, AdvEvent(kind: "log", body: "l1", critical: false)),
                    (4, AdvEvent(kind: "log", body: "extra", critical: false)),
                ])
            ),
            AdvCase(
                "priority_structural_shuffle_criticals_stable", "priority_mix",
                mkRun([
                    (0, AdvEvent(kind: "authorize", body: "a", critical: true)),
                    (1, AdvEvent(kind: "log", body: "l1", critical: false)),
                    (2, AdvEvent(kind: "finalize", body: "f", critical: true)),
                    (3, AdvEvent(kind: "log", body: "l2", critical: false)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "log", body: "l2", critical: false)),
                    (1, AdvEvent(kind: "authorize", body: "a", critical: true)),
                    (2, AdvEvent(kind: "log", body: "l1", critical: false)),
                    (3, AdvEvent(kind: "finalize", body: "f", critical: true)),
                    (4, AdvEvent(kind: "log", body: "extra", critical: false)),
                ])
            ),
            AdvCase(
                "priority_critical_reorder_with_noise", "priority_mix",
                mkRun([
                    (0, AdvEvent(kind: "log", body: "n0", critical: false)),
                    (1, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                    (2, AdvEvent(kind: "log", body: "n1", critical: false)),
                    (3, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
                    (4, AdvEvent(kind: "log", body: "n2", critical: false)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "log", body: "n2", critical: false)),
                    (1, AdvEvent(kind: "generateInvoice", body: "y", critical: true)),
                    (2, AdvEvent(kind: "log", body: "n0", critical: false)),
                    (3, AdvEvent(kind: "createCustomer", body: "x", critical: true)),
                    (4, AdvEvent(kind: "log", body: "n1", critical: false)),
                    (5, AdvEvent(kind: "log", body: "n3", critical: false)),
                ])
            ),
            AdvCase(
                "priority_critical_replaced_by_structural", "priority_mix",
                mkRun([
                    (0, AdvEvent(kind: "decision", body: "validate", critical: true)),
                    (1, AdvEvent(kind: "decision", body: "charge", critical: true)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "decision", body: "telemetry-lookalike", critical: false)),
                    (1, AdvEvent(kind: "decision", body: "charge", critical: true)),
                ])
            ),
            AdvCase(
                "priority_all_structural_reorder", "priority_mix",
                mkRun((0..<6).map { i in (UInt64(i), AdvEvent(kind: "log", body: "l\(i)", critical: false)) }),
                mkRun((0..<6).map { i in (UInt64(i), AdvEvent(kind: "log", body: "l\(5 - i)", critical: false)) })
            ),
        ]
    }

    static func longRepeatedPatternsN(_ nEvents: Int, name: String? = nil) -> AdvCase {
        let pattern = ["plan", "tool_call", "observe", "tool_call", "conclude"]
        let cycles = max(1, nEvents / pattern.count)
        var baseSpecs: [(UInt64, AdvEvent)] = []
        for cycle in 0..<cycles {
            for (i, kind) in pattern.enumerated() {
                let seq = UInt64(cycle * pattern.count + i)
                let crit = kind == "plan" || kind == "conclude"
                baseSpecs.append((seq, AdvEvent(kind: kind, body: "c\(cycle):\(kind)", critical: crit)))
            }
        }
        var compSpecs: [(UInt64, AdvEvent)] = []
        var seq: UInt64 = 0
        for cycle in 0..<cycles {
            var kinds = pattern
            if cycle % 7 == 2 { kinds = ["plan", "tool_call", "tool_call", "observe", "conclude"] }
            if cycle % 11 == 4 { kinds = ["conclude", "plan", "tool_call", "observe", "tool_call"] }
            if cycle % 13 == 3 { kinds = ["plan", "tool_call", "observe", "tool_call"] }
            for kind in kinds {
                let crit = kind == "plan" || kind == "conclude"
                var body = "c\(cycle):\(kind)"
                if cycle % 7 == 2 && kind == "tool_call" && seq % 2 == 0 {
                    body = "c\(cycle):decoy"
                }
                compSpecs.append((seq, AdvEvent(kind: kind, body: body, critical: crit)))
                seq += 1
            }
        }
        return AdvCase(
            name ?? "long_repeated_\(nEvents)",
            "long",
            mkRun(baseSpecs),
            mkRun(compSpecs),
            notes: "n≈\(baseSpecs.count)"
        )
    }

    static func nestedInterleavedDuplicates() -> [AdvCase] {
        var out: [AdvCase] = []
        out.append(AdvCase(
            "nested_duplicates_swap", "duplicates",
            mkRun([
                (0, AdvEvent(kind: "decision", body: "outer-A", critical: true)),
                (1, AdvEvent(kind: "decision", body: "inner-1", critical: true)),
                (2, AdvEvent(kind: "decision", body: "inner-2", critical: true)),
                (3, AdvEvent(kind: "decision", body: "outer-B", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "decision", body: "outer-B", critical: true)),
                (1, AdvEvent(kind: "log", body: "noise", critical: false)),
                (2, AdvEvent(kind: "decision", body: "inner-2", critical: true)),
                (3, AdvEvent(kind: "decision", body: "inner-1", critical: true)),
                (4, AdvEvent(kind: "decision", body: "outer-A", critical: true)),
                (5, AdvEvent(kind: "decision", body: "inner-decoy", critical: true)),
            ])
        ))
        let base2 = mkRun((0..<12).map { i in
            let isA = i % 2 == 0
            return (UInt64(i), AdvEvent(kind: "stream", body: "\(isA ? "A" : "B"):\(i / 2)", critical: isA))
        })
        let aVals = (0..<6).map { "A:\($0)" }
        let bVals = Array((0..<6).map { "B:\($0)" }.reversed())
        var ai = 0
        var bi = 0
        var comp2: [(UInt64, AdvEvent)] = []
        var seq: UInt64 = 0
        for i in 0..<14 {
            if i == 5 {
                comp2.append((seq, AdvEvent(kind: "stream", body: "B:decoy", critical: false)))
                seq += 1
                continue
            }
            if i % 2 == 0 && ai < aVals.count {
                comp2.append((seq, AdvEvent(kind: "stream", body: aVals[ai], critical: true)))
                ai += 1
            } else if bi < bVals.count {
                comp2.append((seq, AdvEvent(kind: "stream", body: bVals[bi], critical: false)))
                bi += 1
            }
            seq += 1
        }
        out.append(AdvCase("interleaved_ab_duplicates", "duplicates", base2, mkRun(comp2)))
        out.append(AdvCase(
            "nested_equal_payload_burst", "ties",
            mkRun((0..<6).map { i in (UInt64(i), AdvEvent(kind: "nest", body: "same", critical: true)) }),
            mkRun(
                (0..<9).map { i in (UInt64(i), AdvEvent(kind: "nest", body: "same", critical: true)) }
                + [(9, AdvEvent(kind: "nest", body: "near", critical: true))]
            )
        ))
        return out
    }

    static func thresholdBoundaryExpanded() -> [AdvCase] {
        var out: [AdvCase] = []
        for (label, a, b) in [
            ("below", "payload-A", "payload-A-almost"),
            ("at", "payload-B", "payload-B"),
            ("above", "payload-C", "payload-C"),
        ] {
            out.append(AdvCase(
                "threshold_boundary_\(label)", "threshold",
                mkRun([(0, AdvEvent(kind: "step", body: a, critical: true))]),
                mkRun([(0, AdvEvent(kind: "step", body: b, critical: true))]),
                notes: label
            ))
        }
        for (label, a, b) in [
            ("near_miss_space", "exact-body", "exact-body "),
            ("near_miss_case", "Exact", "exact"),
            ("identical_pair", "same", "same"),
            ("total_mismatch", "alpha", "omega"),
        ] {
            out.append(AdvCase(
                "threshold_extra_\(label)", "threshold",
                mkRun([(0, AdvEvent(kind: "step", body: a, critical: true))]),
                mkRun([(0, AdvEvent(kind: "step", body: b, critical: true))]),
                notes: label
            ))
        }
        out.append(AdvCase(
            "threshold_mixed_pair", "threshold",
            mkRun([
                (0, AdvEvent(kind: "step", body: "keep", critical: true)),
                (1, AdvEvent(kind: "step", body: "change-me", critical: true)),
            ]),
            mkRun([
                (0, AdvEvent(kind: "step", body: "keep", critical: true)),
                (1, AdvEvent(kind: "step", body: "change-me-almost", critical: true)),
            ])
        ))
        return out
    }

    static func semanticHookFamily() -> [AdvCase] {
        [
            AdvCase(
                "semantic_evaluator_disagree", "semantic_hook",
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "text-A", critical: true, semanticLabel: "cluster-1")),
                    (1, AdvEvent(kind: "claim", body: "text-B", critical: true, semanticLabel: "cluster-2")),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "text-B-paraphrase", critical: true, semanticLabel: "cluster-2")),
                    (1, AdvEvent(kind: "claim", body: "text-A-paraphrase", critical: true, semanticLabel: "cluster-1")),
                ]),
                notes: "SemanticLabel_v1"
            ),
            AdvCase(
                "semantic_three_cluster_cross", "semantic_hook",
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "t0", critical: true, semanticLabel: "c0")),
                    (1, AdvEvent(kind: "claim", body: "t1", critical: true, semanticLabel: "c1")),
                    (2, AdvEvent(kind: "claim", body: "t2", critical: true, semanticLabel: "c2")),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "p2", critical: true, semanticLabel: "c2")),
                    (1, AdvEvent(kind: "claim", body: "p0", critical: true, semanticLabel: "c0")),
                    (2, AdvEvent(kind: "claim", body: "p1", critical: true, semanticLabel: "c1")),
                ]),
                notes: "SemanticLabel_v1"
            ),
            AdvCase(
                "semantic_partial_cluster", "semantic_hook",
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "keep", critical: true, semanticLabel: "same")),
                    (1, AdvEvent(kind: "claim", body: "drift", critical: true, semanticLabel: "x")),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "claim", body: "keep-para", critical: true, semanticLabel: "same")),
                    (1, AdvEvent(kind: "claim", body: "other", critical: true, semanticLabel: "y")),
                ]),
                notes: "SemanticLabel_v1"
            ),
        ]
    }

    static func greedyTrapFamily() -> [AdvCase] {
        [
            AdvCase(
                "greedy_trap_assignment", "collisions",
                mkRun([
                    (0, AdvEvent(kind: "graded", body: "b0", critical: true)),
                    (1, AdvEvent(kind: "graded", body: "b1", critical: true)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "graded", body: "c0", critical: true)),
                    (1, AdvEvent(kind: "graded", body: "c1", critical: true)),
                ]),
                notes: "graded"
            ),
            AdvCase(
                "greedy_trap_3x3", "collisions",
                mkRun((0..<3).map { i in (UInt64(i), AdvEvent(kind: "graded", body: "t3_b\(i)", critical: true)) }),
                mkRun((0..<3).map { j in (UInt64(j), AdvEvent(kind: "graded", body: "t3_c\(j)", critical: true)) }),
                notes: "graded_3x3"
            ),
            AdvCase(
                "greedy_trap_4x4", "collisions",
                mkRun((0..<4).map { i in (UInt64(i), AdvEvent(kind: "graded", body: "t4_b\(i)", critical: true)) }),
                mkRun((0..<4).map { j in (UInt64(j), AdvEvent(kind: "graded", body: "t4_c\(j)", critical: true)) }),
                notes: "graded_4x4"
            ),
            AdvCase(
                "greedy_trap_steal_column", "collisions",
                mkRun([
                    (0, AdvEvent(kind: "graded", body: "steal_b0", critical: true)),
                    (1, AdvEvent(kind: "graded", body: "steal_b1", critical: true)),
                ]),
                mkRun([
                    (0, AdvEvent(kind: "graded", body: "steal_c0", critical: true)),
                    (1, AdvEvent(kind: "graded", body: "steal_c1", critical: true)),
                ]),
                notes: "graded_steal"
            ),
        ]
    }

    /// Deterministic seeded fuzz (LCG) matching Python `random.Random(seed)` intent —
    /// fixed seeds for reproducibility; not bit-identical to CPython RNG.
    static func seededFuzzFamilies(seeds: [UInt64] = [1, 2, 3, 7, 11, 42, 99, 123]) -> [AdvCase] {
        let kinds = ["plan", "tool_call", "observe", "decision", "log", "finalize"]
        return seeds.map { seed in
            var rng = SeededRNG(seed: seed)
            let n = Int(rng.next(in: 50...200))
            var baseSpecs: [(UInt64, AdvEvent)] = []
            for i in 0..<n {
                let kind = kinds[Int(rng.next(in: 0...UInt64(kinds.count - 1)))]
                let crit = kind == "plan" || kind == "decision" || kind == "finalize"
                let body = "s\(seed):\(kind):\(rng.next(in: 0...5))"
                baseSpecs.append((UInt64(i), AdvEvent(kind: kind, body: body, critical: crit)))
            }
            let bodies = baseSpecs.map { $0.1.body }
            let kindsB = baseSpecs.map { $0.1.kind }
            let crits = baseSpecs.map { $0.1.critical }

            var newOrder = Array(0..<n)
            if n >= 10 {
                let lo = Int(rng.next(in: 0...UInt64(n - 10)))
                let hi = lo + Int(rng.next(in: 4...10))
                var window = Array(lo..<hi)
                for i in stride(from: window.count - 1, through: 1, by: -1) {
                    let j = Int(rng.next(in: 0...UInt64(i)))
                    window.swapAt(i, j)
                }
                for (idx, src) in window.enumerated() {
                    newOrder[lo + idx] = src
                }
            }

            var deleted = Set<Int>()
            if n >= 10 {
                let k = min(n / 10, 8)
                while deleted.count < k {
                    deleted.insert(Int(rng.next(in: 0...UInt64(n - 1))))
                }
            }

            var compSpecs: [(UInt64, AdvEvent)] = []
            var seq: UInt64 = 0
            for src in newOrder {
                if deleted.contains(src) { continue }
                var body = bodies[src]
                let kind = kindsB[src]
                let crit = crits[src]
                if rng.nextDouble() < 0.08 { body += "-near" }
                compSpecs.append((seq, AdvEvent(kind: kind, body: body, critical: crit)))
                seq += 1
                if rng.nextDouble() < 0.06 {
                    let decoyKind = kinds[Int(rng.next(in: 0...UInt64(kinds.count - 1)))]
                    let decoyCrit = decoyKind == "plan" || decoyKind == "decision"
                    compSpecs.append((seq, AdvEvent(kind: decoyKind, body: "decoy-\(seed)-\(seq)", critical: decoyCrit)))
                    seq += 1
                }
            }
            return AdvCase(
                "fuzz_seed_\(seed)_n\(n)",
                "fuzz",
                mkRun(baseSpecs),
                mkRun(compSpecs),
                notes: "seed=\(seed)"
            )
        }
    }
}

/// Tiny deterministic LCG for fuzz generators (test-only).
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 0x9E3779B97F4A7C15 &+ 0x6A09E667F3BCC909 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1
        return state
    }
    mutating func next(in range: ClosedRange<UInt64>) -> UInt64 {
        let span = range.upperBound - range.lowerBound + 1
        return range.lowerBound + (next() % span)
    }
    mutating func nextDouble() -> Double {
        Double(next() % 10_000) / 10_000.0
    }
}
