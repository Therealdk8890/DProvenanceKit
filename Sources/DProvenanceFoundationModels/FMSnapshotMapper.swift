import Foundation
import DProvenanceKit

/// A payload plus the nested span names it belongs under.
public struct FMMappedEvent: Sendable, Equatable {
    public let payload: FoundationModelTraceEvent
    /// Nested span names outermost-first, e.g.
    /// ["fm.turn.0", "fm.turn.0.tool.WeatherTool.0"].
    /// Empty = run root (instructions, availability, unknown-outside-turn).
    public let spanPath: [String]
}

/// The pure snapshot-to-events mapper. Deterministic: the same snapshot maps
/// to the same event array, byte for byte, on every OS the package supports.
public struct FMSnapshotMapper: Sendable {
    public let configuration: FMTracingConfiguration

    public init(configuration: FMTracingConfiguration = .default) {
        self.configuration = configuration
    }

    /// Mapping rules:
    /// - each `.prompt` entry starts turn i (0-based);
    /// - `.toolCalls` fans out one fm_tool_call per Call with a
    ///   per-(turn, toolName) invocationIndex;
    /// - `.toolOutput` pairs to the k-th same-name call in the turn by order;
    /// - instructions are filtered when `configuration.recordInstructions`
    ///   is false;
    /// - `.unknown` maps to fm_unknown_entry.
    /// Events emerge in entry order; redaction is applied per the
    /// configuration's field policies.
    public func map(_ snapshot: FMTranscriptSnapshot) -> [FMMappedEvent] {
        map(snapshot, in: 0..<snapshot.entries.count, startingTurnIndex: 0)
    }

    /// Incremental form for resuming ingestion: mapping entries[r...] with
    /// `startingTurnIndex` = number of prompts in entries[..<r] equals the
    /// suffix of the full map. Entries that require a turn but precede any
    /// prompt in the mapped range attach to the last started turn
    /// (`startingTurnIndex - 1`), matching what a full map would have
    /// assigned them; per-turn invocation counters cannot be recovered
    /// mid-turn, so resume at turn boundaries when tool entries are involved.
    public func map(_ snapshot: FMTranscriptSnapshot, in range: Range<Int>, startingTurnIndex: Int) -> [FMMappedEvent] {
        mapWithOrigins(snapshot, in: range, startingTurnIndex: startingTurnIndex).map(\.event)
    }
}

extension FMSnapshotMapper {
    /// A mapped event plus the snapshot entry index it derives from, so
    /// callers that dedupe by transcript entry id can attribute fan-out
    /// events (one `.toolCalls` entry produces several) to their entry.
    struct OriginatedEvent: Sendable, Equatable {
        let event: FMMappedEvent
        let entryIndex: Int
    }

    func mapWithOrigins(
        _ snapshot: FMTranscriptSnapshot,
        in range: Range<Int>,
        startingTurnIndex: Int
    ) -> [OriginatedEvent] {
        let policy = configuration.redaction
        let label = configuration.sessionLabel
        let clamped = range.clamped(to: 0..<snapshot.entries.count)

        var out: [OriginatedEvent] = []
        var nextTurnIndex = startingTurnIndex
        var currentTurn: Int? = nil
        var callCounts: [String: Int] = [:]
        var outputCounts: [String: Int] = [:]

        func activeTurn() -> Int { currentTurn ?? max(startingTurnIndex - 1, 0) }
        func turnSpan() -> String { FMSpanPath.turn(activeTurn(), sessionLabel: label) }

        for index in clamped {
            switch snapshot.entries[index] {
            case .instructions(let text, let toolNames, let toolDescriptions):
                guard configuration.recordInstructions else { break }
                let payload = FMInstructionsPayload(
                    content: FMRedactedText(text, redaction: policy.instructionsContent),
                    toolNames: toolNames,
                    toolDescriptions: toolDescriptions
                )
                out.append(OriginatedEvent(
                    event: FMMappedEvent(payload: .instructions(payload), spanPath: []),
                    entryIndex: index
                ))

            case .prompt(let text, let options, let responseFormatName):
                let turn = nextTurnIndex
                nextTurnIndex += 1
                currentTurn = turn
                callCounts = [:]
                outputCounts = [:]
                let payload = FMPromptPayload(
                    content: FMRedactedText(text, redaction: policy.promptContent),
                    options: options,
                    responseFormatName: responseFormatName,
                    turnIndex: turn
                )
                out.append(OriginatedEvent(
                    event: FMMappedEvent(payload: .prompt(payload), spanPath: [turnSpan()]),
                    entryIndex: index
                ))

            case .toolCalls(let calls):
                for call in calls {
                    let k = callCounts[call.toolName, default: 0]
                    callCounts[call.toolName] = k + 1
                    let payload = FMToolCallPayload(
                        toolName: call.toolName,
                        arguments: FMRedactedText(call.argumentsJSON, redaction: policy.toolArguments),
                        turnIndex: activeTurn(),
                        invocationIndex: k
                    )
                    let toolSpan = FMSpanPath.tool(
                        named: call.toolName, invocation: k, turnIndex: activeTurn(), sessionLabel: label
                    )
                    out.append(OriginatedEvent(
                        event: FMMappedEvent(payload: .toolCall(payload), spanPath: [turnSpan(), toolSpan]),
                        entryIndex: index
                    ))
                }

            case .toolOutput(let toolName, let text):
                let k = outputCounts[toolName, default: 0]
                outputCounts[toolName] = k + 1
                let payload = FMToolOutputPayload(
                    toolName: toolName,
                    content: FMRedactedText(text, redaction: policy.toolOutput),
                    isError: false,
                    turnIndex: activeTurn(),
                    invocationIndex: k
                )
                let toolSpan = FMSpanPath.tool(
                    named: toolName, invocation: k, turnIndex: activeTurn(), sessionLabel: label
                )
                out.append(OriginatedEvent(
                    event: FMMappedEvent(payload: .toolOutput(payload), spanPath: [turnSpan(), toolSpan]),
                    entryIndex: index
                ))

            case .response(let text, let assetIDCount):
                let payload = FMResponsePayload(
                    content: FMRedactedText(text, redaction: policy.responseContent),
                    assetIDCount: assetIDCount,
                    turnIndex: activeTurn()
                )
                out.append(OriginatedEvent(
                    event: FMMappedEvent(payload: .response(payload), spanPath: [turnSpan()]),
                    entryIndex: index
                ))

            case .unknown(let description):
                let turn = currentTurn ?? (startingTurnIndex > 0 ? startingTurnIndex - 1 : nil)
                let payload = FMUnknownEntryPayload(
                    kindDescription: FMRedactedText(description, redaction: policy.errorMessages),
                    turnIndex: turn
                )
                let spanPath = turn.map { [FMSpanPath.turn($0, sessionLabel: label)] } ?? []
                out.append(OriginatedEvent(
                    event: FMMappedEvent(payload: .unknownEntry(payload), spanPath: spanPath),
                    entryIndex: index
                ))
            }
        }
        return out
    }
}
