import Foundation
import DProvenanceKit

// Measures the alignment and diff engines' wall-clock cost as trace size grows, so
// BENCHMARKS.md's operating envelope is a measurement anyone can reproduce, not a
// claim. Deterministic by construction: a fixed-seed SplitMix64 drives every
// perturbation, so two runs on the same machine time the same work.
//
// Usage:
//   swift run -c release AlignmentScaleBenchmark                 # full ladder
//   swift run -c release AlignmentScaleBenchmark --sizes 100,1000
//
// The matcher scores every base×comparison event pair, so cost grows quadratically
// in trace size — the point of this tool is to keep the practical consequences of
// that measured and honest rather than discovered in production.

struct BenchEvent: TraceableEvent {
    let type: String
    let body: String
    let critical: Bool
    var typeIdentifier: String { type }
    var priority: TracePriority { critical ? .critical : .structural }
}

/// Deterministic PRNG so the generated traces (and therefore the timed work) are
/// identical across runs and machines.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let runID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
let epoch = Date(timeIntervalSince1970: 1_752_800_000)

func makeEvent(_ seq: UInt64, type: String, body: String, critical: Bool) -> TraceEvent<BenchEvent> {
    TraceEvent(runID: runID, contextID: "bench", engineName: "bench", schemaVersion: 1,
               sequence: seq, spanID: nil, parentSpanID: nil,
               payload: BenchEvent(type: type, body: body, critical: critical),
               timestamp: epoch)
}

/// `distinctTypes` controls matching ambiguity: n distinct types is the easy case
/// (each event has one same-type candidate); a small pool means every event has
/// n/pool same-type candidates and the matcher's candidate list balloons.
func makeBase(n: Int, distinctTypes: Int) -> TraceRun<BenchEvent> {
    let events = (0..<n).map { i in
        makeEvent(UInt64(i), type: "step_\(i % distinctTypes)", body: "body_\(i)",
                  critical: i % 10 == 0)
    }
    return TraceRun(runID: runID, contextID: "bench", events: events)
}

/// A realistic comparison: ~1% of payloads drift, ~1% of events are dropped, and one
/// adjacent non-critical pair swaps — enough to exercise the changed/removed/reorder
/// paths without changing the workload's asymptotic shape.
func makeComparison(from base: TraceRun<BenchEvent>, rng: inout SplitMix64) -> TraceRun<BenchEvent> {
    var events = base.events
    let n = events.count
    for _ in 0..<max(1, n / 100) {
        let i = Int(rng.next() % UInt64(n))
        let e = events[i]
        events[i] = makeEvent(e.sequence, type: e.payload.type,
                              body: e.payload.body + "_drift", critical: e.payload.critical)
    }
    for _ in 0..<max(1, n / 100) {
        events.remove(at: Int(rng.next() % UInt64(events.count)))
    }
    let i = Int(rng.next() % UInt64(events.count - 1))
    if !events[i].payload.critical && !events[i + 1].payload.critical {
        events.swapAt(i, i + 1)
    }
    return TraceRun(runID: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
                    contextID: "bench", events: events)
}

func measure(_ label: String, _ work: () -> Void) -> Double {
    let start = DispatchTime.now()
    work()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    print(String(format: "  %-34s %8.3f s", (label as NSString).utf8String!, seconds))
    return seconds
}

// MARK: - Arguments

var sizes = [100, 1_000, 10_000]
var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
    args.removeFirst()
    switch flag {
    case "--sizes":
        guard let spec = args.first else { fatalError("--sizes needs a comma-separated list") }
        args.removeFirst()
        sizes = spec.split(separator: ",").compactMap { Int($0) }
    default:
        fatalError("unknown argument: \(flag)")
    }
}

// MARK: - Run

let config = AlignmentConfiguration(
    profile: .strictAuditV1,
    equivalenceEvaluator: AnyEquivalenceEvaluator<BenchEvent>(identifier: "eq") { a, b in
        a == b ? 1.0 : (a.type == b.type ? 0.8 : 0.0)
    })
let engine = TraceAlignmentEngine(configuration: config)
let diffEngine = TraceDiffEngine<BenchEvent>()

print("AlignmentScaleBenchmark — deterministic synthetic traces, release-mode timings")
print("machine: \(ProcessInfo.processInfo.machineHardwareName ?? "unknown"), \(ProcessInfo.processInfo.processorCount) cores")

for n in sizes {
    var rng = SplitMix64(seed: 42)
    print("\nn = \(n) events (10% critical)")

    let easyBase = makeBase(n: n, distinctTypes: n)
    let easyComp = makeComparison(from: easyBase, rng: &rng)
    _ = measure("align, distinct types") { _ = engine.align(base: easyBase, comparison: easyComp) }

    let hardBase = makeBase(n: n, distinctTypes: 10)
    let hardComp = makeComparison(from: hardBase, rng: &rng)
    _ = measure("align, 10-type ambiguity stress") { _ = engine.align(base: hardBase, comparison: hardComp) }

    _ = measure("diff, distinct types") { _ = diffEngine.diff(base: easyBase, comparison: easyComp) }
}

extension ProcessInfo {
    var machineHardwareName: String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var chars = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(decoding: chars.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
