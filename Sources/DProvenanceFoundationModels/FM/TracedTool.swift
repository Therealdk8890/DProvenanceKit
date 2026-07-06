#if canImport(FoundationModels)
import Foundation
import Synchronization
import FoundationModels
import DProvenanceKit

/// Wraps any Tool so its invocations are traced.
///
/// `Arguments = GeneratedContent` (Generable, hence a valid
/// ConvertibleFromGeneratedContent) so the RAW arguments are captured for ANY
/// base tool BEFORE typed decoding — a decode failure is itself evidence and
/// must not lose the fm_tool_call. The model sees the identical schema
/// because `parameters` forwards the base tool's.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct TracedTool<Base: Tool>: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = Base.Output

    /// The untraced tool, also usable as an escape hatch.
    public let base: Base

    let configuration: FMTracingConfiguration
    private let context: FMToolCaptureContext?
    private let standaloneCounter: FMStandaloneInvocationCounter

    /// Standalone mode: for use with a plain LanguageModelSession. Records
    /// via ambient task-locals (best effort — a runtime that detaches tool
    /// invocation loses the ambient run; session-owned wrapping via
    /// TracedLanguageModelSession is detachment-proof).
    public init(_ base: Base, configuration: FMTracingConfiguration = .default) {
        self.base = base
        self.configuration = configuration
        self.context = nil
        self.standaloneCounter = FMStandaloneInvocationCounter()
    }

    /// Session-owned mode: records through the capture context's re-bound
    /// run handle, surviving detached invocation.
    init(_ base: Base, context: FMToolCaptureContext) {
        self.base = base
        self.configuration = context.configuration
        self.context = context
        self.standaloneCounter = FMStandaloneInvocationCounter()
    }

    public var name: String { base.name }
    public var description: String { base.description }
    public var parameters: GenerationSchema { base.parameters }
    public var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    @concurrent public func call(arguments: GeneratedContent) async throws -> Base.Output {
        let turnIndex: Int
        let invocationIndex: Int
        let spanPath: [String]
        if let context {
            let resolved = context.beginToolCall(named: name)
            turnIndex = resolved.turnIndex
            invocationIndex = resolved.invocationIndex
            spanPath = [resolved.turnSpanName, resolved.toolSpanName]
        } else {
            turnIndex = 0
            invocationIndex = standaloneCounter.next()
            spanPath = [FMSpanPath.standaloneTool(
                named: name, invocation: invocationIndex, sessionLabel: configuration.sessionLabel
            )]
        }

        let callDelivered = record(.toolCall(FMToolCallPayload(
            toolName: name,
            arguments: FMRedactedText(arguments.jsonString, redaction: configuration.redaction.toolArguments, redactor: configuration.redaction.redactor),
            turnIndex: turnIndex,
            invocationIndex: invocationIndex
        )), spanPath: spanPath)
        if callDelivered {
            context?.markLiveToolCall(turnIndex: turnIndex, toolName: name, invocationIndex: invocationIndex)
        }

        let typedArguments: Base.Arguments
        do {
            typedArguments = try Base.Arguments(arguments)
        } catch {
            record(.generationError(FMGenerationErrorPayload(
                kind: .toolCallError,
                message: FMRedactedText(String(describing: error), redaction: configuration.redaction.errorMessages, redactor: configuration.redaction.redactor),
                toolName: name,
                turnIndex: turnIndex
            )), spanPath: spanPath)
            throw error
        }

        do {
            let output = try await runInSpan(spanPath) {
                try await base.call(arguments: typedArguments)
            }
            let outputText: String
            if let convertible = output as? any ConvertibleToGeneratedContent {
                outputText = convertible.generatedContent.jsonString
            } else {
                outputText = String(describing: output)
            }
            let outputDelivered = record(.toolOutput(FMToolOutputPayload(
                toolName: name,
                content: FMRedactedText(outputText, redaction: configuration.redaction.toolOutput, redactor: configuration.redaction.redactor),
                isError: false,
                turnIndex: turnIndex,
                invocationIndex: invocationIndex
            )), spanPath: spanPath)
            if outputDelivered {
                context?.markLiveToolOutput(turnIndex: turnIndex, toolName: name, invocationIndex: invocationIndex)
            }
            return output
        } catch {
            let outputDelivered = record(.toolOutput(FMToolOutputPayload(
                toolName: name,
                content: FMRedactedText(String(describing: error), redaction: configuration.redaction.toolOutput, redactor: configuration.redaction.redactor),
                isError: true,
                turnIndex: turnIndex,
                invocationIndex: invocationIndex
            )), spanPath: spanPath)
            record(.generationError(FMGenerationErrorPayload(
                kind: .toolCallError,
                message: FMRedactedText(String(describing: error), redaction: configuration.redaction.errorMessages, redactor: configuration.redaction.redactor),
                toolName: name,
                turnIndex: turnIndex
            )), spanPath: spanPath)
            if outputDelivered {
                context?.markLiveToolOutput(turnIndex: turnIndex, toolName: name, invocationIndex: invocationIndex)
            }
            throw error
        }
    }

    /// Returns whether the record could deliver; callers gate live-copy
    /// dedupe markers on it (see FMToolCaptureContext.record).
    @discardableResult
    private func record(_ event: FoundationModelTraceEvent, spanPath: [String]) -> Bool {
        if let context {
            return context.record(event, spanPath: spanPath)
        }
        var delivered = false
        configuration.withDefaultEngine {
            FMSnapshotIngestion.replaySpans(spanPath[...]) {
                delivered = configuration.recorder.canDeliver()
                configuration.recorder.record(event)
            }
        }
        return delivered
    }

    /// Runs the base tool INSIDE the tool span (and, when detached with a
    /// session context, inside the captured run) so the app's own
    /// DProvenanceKit events nest under the tool node.
    private func runInSpan<R>(_ spanPath: [String], _ body: () async throws -> R) async rethrows -> R {
        guard let leaf = spanPath.last else { return try await body() }
        let parent = spanPath.count >= 2 ? spanPath[spanPath.count - 2] : TraceContext.currentSpanID

        if TraceContext.currentRun == nil, let capturedRun = context?.capturedRun {
            return try await TraceContext.$currentRun.withValue(capturedRun) {
                try await TraceContext.$currentSpanID.withValue(leaf) {
                    try await TraceContext.$parentSpanID.withValue(parent) {
                        try await body()
                    }
                }
            }
        }
        return try await TraceContext.$currentSpanID.withValue(leaf) {
            try await TraceContext.$parentSpanID.withValue(parent) {
                try await body()
            }
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension Tool {
    public func traced(configuration: FMTracingConfiguration = .default) -> TracedTool<Self> {
        TracedTool(self, configuration: configuration)
    }
}

/// Per-instance invocation ordinal for standalone tools; a class so copies of
/// the TracedTool struct share one counter, keeping standalone span names
/// ("fm.tool.Name.k") strictly increasing per wrapped instance.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
final class FMStandaloneInvocationCounter: Sendable {
    private let value = Mutex(0)

    func next() -> Int {
        value.withLock { current in
            let next = current
            current += 1
            return next
        }
    }
}
#endif
