import Foundation
import DProvenanceKit

/// Stream partial-snapshot telemetry capture. Defaults to `.off`: snapshots
/// are high-frequency and carry length-only payloads even when enabled.
public enum FMStreamSnapshotCapture: Sendable, Equatable {
    case off
    case everySnapshot
    case sampled(everyNth: Int)
}

public struct FMTracingConfiguration: Sendable {
    public var redaction: FMRedactionPolicy
    public var recorder: FMEventRecorder
    public var engineName: String
    /// Span-path prefix for multi-session runs: "fm[label].turn.0".
    public var sessionLabel: String?
    public var recordAvailabilityOnFirstUse: Bool
    public var recordInstructions: Bool
    public var streamSnapshots: FMStreamSnapshotCapture

    public init(
        redaction: FMRedactionPolicy = .full,
        recorder: FMEventRecorder = .automatic,
        engineName: String = "FoundationModels",
        sessionLabel: String? = nil,
        recordAvailabilityOnFirstUse: Bool = true,
        recordInstructions: Bool = true,
        streamSnapshots: FMStreamSnapshotCapture = .off
    ) {
        self.redaction = redaction
        self.recorder = recorder
        self.engineName = engineName
        self.sessionLabel = sessionLabel
        self.recordAvailabilityOnFirstUse = recordAvailabilityOnFirstUse
        self.recordInstructions = recordInstructions
        self.streamSnapshots = streamSnapshots
    }

    public static let `default` = FMTracingConfiguration()

    static let defaultEngineName = "FoundationModels"
}

extension FMTracingConfiguration {
    /// Every record path wraps in `withEngineSync(name: engineName)` ONLY when
    /// the caller's engine stack is empty; a caller-established engine is
    /// always respected.
    func withDefaultEngine<R>(_ body: () throws -> R) rethrows -> R {
        guard TraceContext.engineStack.isEmpty else { return try body() }
        return try DProvenanceKit<FoundationModelTraceEvent>.withEngineSync(name: engineName) {
            try body()
        }
    }

    func record(_ event: FoundationModelTraceEvent) {
        withDefaultEngine { recorder.record(event) }
    }
}
