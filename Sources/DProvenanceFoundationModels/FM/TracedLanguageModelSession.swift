// `nonisolated(nonsending)` below is Swift 6.2+ syntax, and inactive `#if canImport`
// regions must still PARSE — only compiler()/swift() conditions exempt their inactive
// branch from parsing (it is lexed only). Without this outer gate, a Swift 6.0/6.1
// consumer build fails at parse time even though FoundationModels is not importable
// there (#57). Deployment floors are unchanged; on older toolchains this file simply
// compiles out, exactly as it already did on SDKs without FoundationModels.
#if compiler(>=6.2)
#if canImport(FoundationModels)
import Foundation
import FoundationModels
import DProvenanceKit

/// Capture mode 2: live. Composition over LanguageModelSession (the FM
/// session is final and `@_hasMissingDesignatedInitializers`, so it cannot be
/// subclassed). Compiler-checked Sendable: all stored properties are Sendable
/// lets — no `@unchecked` anywhere in this target.
///
/// Mirrors carry `@_disfavoredOverload` exactly where Apple's declarations do
/// (String-prompt respond/stream overloads; the String? instructions init) so
/// overload resolution matches the SDK.
///
/// TURN ALGORITHM (all respond mirrors):
/// 0. lazily on first use: record fm_model_availability + fm_instructions
///    (config-gated) at run root;
/// 1. open turn span FMSpanPath.turn(i, sessionLabel:);
/// 2. record fm_prompt BEFORE awaiting for String overloads (survives
///    hang/crash). Prompt/@PromptBuilder overloads have no public text
///    accessor, so their fm_prompt is recorded at reconciliation from the
///    transcript — deterministic per call shape (a caller migrating
///    String -> builder sees a one-time event-order diff in that turn);
/// 3. arm the capture context (run handle, turnIndex, invocation counters);
/// 4. await base.respond (nonisolated(nonsending) => caller isolation); on
///    throw record fm_generation_error, reconcile whatever transcript delta
///    exists, rethrow unchanged;
/// 5. reconcile response.transcriptEntries via the snapshot bridge + mapper
///    in transcript order, re-entering the SAME span names (identical
///    strings => identical spanID/parentSpanID), skipping events recorded
///    live. Canonical content ALWAYS derives from the transcript — the
///    live/post-hoc parity linchpin.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
@dynamicMemberLookup
public final class TracedLanguageModelSession: Sendable {
    /// The wrapped session — the untraced escape hatch.
    public let base: LanguageModelSession
    public let configuration: FMTracingConfiguration

    let context: FMToolCaptureContext
    private let model: SystemLanguageModel

    public var transcript: Transcript { base.transcript }
    public var isResponding: Bool { base.isResponding }

    /// Future-proof passthrough for LanguageModelSession API this wrapper
    /// does not mirror.
    public subscript<V>(dynamicMember keyPath: KeyPath<LanguageModelSession, V>) -> V {
        base[keyPath: keyPath]
    }

    @_disfavoredOverload
    public init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: String? = nil,
        configuration: FMTracingConfiguration = .default
    ) {
        let context = FMToolCaptureContext(configuration: configuration, startingTurnIndex: 0, liveToolTracing: true)
        self.base = LanguageModelSession(
            model: model, tools: Self.wrapped(tools, context: context), instructions: instructions
        )
        self.configuration = configuration
        self.context = context
        self.model = model
    }

    public init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        instructions: Instructions? = nil,
        configuration: FMTracingConfiguration = .default
    ) {
        let context = FMToolCaptureContext(configuration: configuration, startingTurnIndex: 0, liveToolTracing: true)
        self.base = LanguageModelSession(
            model: model, tools: Self.wrapped(tools, context: context), instructions: instructions
        )
        self.configuration = configuration
        self.context = context
        self.model = model
    }

    public init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        configuration: FMTracingConfiguration = .default,
        @InstructionsBuilder instructions: () throws -> Instructions
    ) rethrows {
        let built = try instructions()
        let context = FMToolCaptureContext(configuration: configuration, startingTurnIndex: 0, liveToolTracing: true)
        self.base = LanguageModelSession(
            model: model, tools: Self.wrapped(tools, context: context), instructions: built
        )
        self.configuration = configuration
        self.context = context
        self.model = model
    }

    /// The turn counter is seeded from the transcript's existing prompt-entry
    /// count so this wrapper's span paths align with post-hoc ingestion of
    /// the same transcript. Does NOT auto-ingest the history — call
    /// `recordProvenance()` for that.
    public init(
        model: SystemLanguageModel = .default,
        tools: [any Tool] = [],
        transcript: Transcript,
        configuration: FMTracingConfiguration = .default
    ) {
        let context = FMToolCaptureContext(
            configuration: configuration,
            startingTurnIndex: Self.promptCount(in: transcript),
            liveToolTracing: true
        )
        self.base = LanguageModelSession(
            model: model, tools: Self.wrapped(tools, context: context), transcript: transcript
        )
        self.configuration = configuration
        self.context = context
        self.model = model
    }

    /// Wraps an existing session. Its tools cannot be re-wrapped, so tool
    /// events come from post-turn reconciliation instead of live child spans
    /// (liveToolTracing = false).
    public init(wrapping session: LanguageModelSession, configuration: FMTracingConfiguration = .default) {
        self.context = FMToolCaptureContext(
            configuration: configuration,
            startingTurnIndex: Self.promptCount(in: session.transcript),
            liveToolTracing: false
        )
        self.base = session
        self.configuration = configuration
        self.model = .default
    }

    public func prewarm(promptPrefix: Prompt? = nil) {
        base.prewarm(promptPrefix: promptPrefix)
    }

    // MARK: respond mirrors (Response<String>)

    @discardableResult
    nonisolated(nonsending) public func respond(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<String> {
        try await tracedRespond(livePromptText: nil, responseFormatName: nil, options: options) {
            try await $0.respond(to: prompt, options: options)
        }
    }

    @discardableResult @_disfavoredOverload
    nonisolated(nonsending) public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<String> {
        try await tracedRespond(livePromptText: prompt, responseFormatName: nil, options: options) {
            try await $0.respond(to: prompt, options: options)
        }
    }

    @discardableResult
    nonisolated(nonsending) public func respond(
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> LanguageModelSession.Response<String> {
        let built = try prompt()
        return try await respond(to: built, options: options)
    }

    // MARK: respond mirrors (schema -> Response<GeneratedContent>)

    @discardableResult
    nonisolated(nonsending) public func respond(
        to prompt: Prompt,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<GeneratedContent> {
        try await tracedRespond(livePromptText: nil, responseFormatName: nil, options: options) {
            try await $0.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @discardableResult @_disfavoredOverload
    nonisolated(nonsending) public func respond(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<GeneratedContent> {
        try await tracedRespond(
            livePromptText: prompt,
            responseFormatName: Transcript.ResponseFormat(schema: schema).name,
            options: options
        ) {
            try await $0.respond(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @discardableResult
    nonisolated(nonsending) public func respond(
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> LanguageModelSession.Response<GeneratedContent> {
        let built = try prompt()
        return try await respond(to: built, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    // MARK: respond mirrors (generating -> Response<Content>)

    @discardableResult
    nonisolated(nonsending) public func respond<Content: Generable>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<Content> {
        try await tracedRespond(livePromptText: nil, responseFormatName: nil, options: options) {
            try await $0.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @discardableResult @_disfavoredOverload
    nonisolated(nonsending) public func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> LanguageModelSession.Response<Content> {
        try await tracedRespond(
            livePromptText: prompt,
            responseFormatName: Transcript.ResponseFormat(type: Content.self).name,
            options: options
        ) {
            try await $0.respond(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @discardableResult
    nonisolated(nonsending) public func respond<Content: Generable>(
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) async throws -> LanguageModelSession.Response<Content> {
        let built = try prompt()
        return try await respond(to: built, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    // MARK: streamResponse mirrors (TracedResponseStream<String>)

    public func streamResponse(
        to prompt: Prompt,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<String> {
        tracedStream(livePromptText: nil, responseFormatName: nil, options: options) {
            $0.streamResponse(to: prompt, options: options)
        }
    }

    @_disfavoredOverload
    public func streamResponse(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<String> {
        tracedStream(livePromptText: prompt, responseFormatName: nil, options: options) {
            $0.streamResponse(to: prompt, options: options)
        }
    }

    public func streamResponse(
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> sending TracedResponseStream<String> {
        let built = try prompt()
        return streamResponse(to: built, options: options)
    }

    // MARK: streamResponse mirrors (schema -> TracedResponseStream<GeneratedContent>)

    public func streamResponse(
        to prompt: Prompt,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<GeneratedContent> {
        tracedStream(livePromptText: nil, responseFormatName: nil, options: options) {
            $0.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @_disfavoredOverload
    public func streamResponse(
        to prompt: String,
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<GeneratedContent> {
        tracedStream(
            livePromptText: prompt,
            responseFormatName: Transcript.ResponseFormat(schema: schema).name,
            options: options
        ) {
            $0.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    public func streamResponse(
        schema: GenerationSchema,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> sending TracedResponseStream<GeneratedContent> {
        let built = try prompt()
        return streamResponse(to: built, schema: schema, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    // MARK: streamResponse mirrors (generating -> TracedResponseStream<Content>)

    public func streamResponse<Content: Generable>(
        to prompt: Prompt,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<Content> {
        tracedStream(livePromptText: nil, responseFormatName: nil, options: options) {
            $0.streamResponse(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    @_disfavoredOverload
    public func streamResponse<Content: Generable>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions()
    ) -> sending TracedResponseStream<Content> {
        tracedStream(
            livePromptText: prompt,
            responseFormatName: Transcript.ResponseFormat(type: Content.self).name,
            options: options
        ) {
            $0.streamResponse(to: prompt, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
        }
    }

    public func streamResponse<Content: Generable>(
        generating type: Content.Type = Content.self,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = GenerationOptions(),
        @PromptBuilder prompt: () throws -> Prompt
    ) rethrows -> sending TracedResponseStream<Content> {
        let built = try prompt()
        return streamResponse(to: built, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    // MARK: post-hoc sweep

    /// Post-hoc sweep that DEDUPES against everything this wrapper recorded
    /// live (by transcript entry id), so it is safe to call repeatedly — the
    /// documented recovery for an abandoned stream.
    @discardableResult
    public func recordProvenance() -> FMIngestionSummary {
        let transcript = base.transcript
        let nextEntryIndex = transcript.endIndex
        guard context.canDeliverNow() else {
            return FMIngestionSummary(
                eventCount: 0, turnCount: 0, toolCallCount: 0,
                skippedSegmentCount: 0, nextEntryIndex: nextEntryIndex
            )
        }
        let outcome = reconcile(entries: transcript, startingTurnIndex: 0)
        return FMIngestionSummary(
            eventCount: outcome.events,
            turnCount: outcome.turns,
            toolCallCount: outcome.toolCalls,
            skippedSegmentCount: outcome.skippedSegments,
            nextEntryIndex: nextEntryIndex
        )
    }

    // MARK: internals

    private static func promptCount(in transcript: Transcript) -> Int {
        transcript.reduce(into: 0) { count, entry in
            if case .prompt = entry { count += 1 }
        }
    }

    /// Tool wrapping opens the existential so TracedTool preserves the
    /// concrete Base type (typed argument decoding, exact schema forwarding).
    private static func wrapped(_ tools: [any Tool], context: FMToolCaptureContext) -> [any Tool] {
        tools.map { wrap($0, context: context) }
    }

    private static func wrap(_ tool: some Tool, context: FMToolCaptureContext) -> any Tool {
        TracedTool(tool, context: context)
    }

    private func recordSessionPreambleIfNeeded() {
        // The one-shot claim and the entry-id mark are spent only when a
        // record can actually land — otherwise a session first used outside
        // a run would lose fm_instructions forever and defeat the documented
        // recordProvenance() backfill.
        guard context.canDeliverNow() else { return }
        guard context.claimSessionPreamble() else { return }
        if configuration.recordAvailabilityOnFirstUse {
            context.record(.modelAvailability(FMModelAvailabilityPayload(model: model)), spanPath: [])
        }
        guard configuration.recordInstructions else { return }
        for entry in base.transcript {
            guard case .instructions = entry else { continue }
            let bridged = FMTranscriptBridge.bridge([entry])
            if case .instructions(let text, let toolNames, let toolDescriptions) = bridged.snapshot.entries.first {
                let delivered = context.record(.instructions(FMInstructionsPayload(
                    content: FMRedactedText(text, redaction: configuration.redaction.instructionsContent, redactor: configuration.redaction.redactor),
                    toolNames: toolNames,
                    toolDescriptions: toolDescriptions
                )), spanPath: [])
                if delivered {
                    context.markEntriesRecorded([entry.id])
                }
            }
            break
        }
    }

    nonisolated(nonsending) private func tracedRespond<Content: Generable>(
        livePromptText: String?,
        responseFormatName: String?,
        options: GenerationOptions,
        _ perform: (LanguageModelSession) async throws -> LanguageModelSession.Response<Content>
    ) async throws -> LanguageModelSession.Response<Content> {
        recordSessionPreambleIfNeeded()
        let transcriptStartIndex = base.transcript.endIndex
        let (turnIndex, spanName) = context.beginTurn(promptOrdinal: Self.promptCount(in: base.transcript))
        if let livePromptText {
            recordLivePrompt(
                text: livePromptText, options: options,
                responseFormatName: responseFormatName, turnIndex: turnIndex, spanName: spanName
            )
        }
        do {
            let response = try await perform(base)
            reconcile(entries: response.transcriptEntries, startingTurnIndex: turnIndex)
            return response
        } catch {
            context.record(
                .generationError(FMGenerationErrorPayload(
                    error: error, turnIndex: turnIndex, redaction: configuration.redaction
                )),
                spanPath: [spanName]
            )
            reconcile(entries: base.transcript[transcriptStartIndex...], startingTurnIndex: turnIndex)
            throw error
        }
    }

    private func tracedStream<Content: Generable>(
        livePromptText: String?,
        responseFormatName: String?,
        options: GenerationOptions,
        _ perform: (LanguageModelSession) -> LanguageModelSession.ResponseStream<Content>
    ) -> TracedResponseStream<Content> {
        recordSessionPreambleIfNeeded()
        let transcriptStartIndex = base.transcript.endIndex
        let (turnIndex, spanName) = context.beginTurn(promptOrdinal: Self.promptCount(in: base.transcript))
        if let livePromptText {
            recordLivePrompt(
                text: livePromptText, options: options,
                responseFormatName: responseFormatName, turnIndex: turnIndex, spanName: spanName
            )
        }
        return TracedResponseStream(
            base: perform(base),
            coordinator: FMStreamTurnCoordinator(
                session: self,
                turnIndex: turnIndex,
                turnSpanName: spanName,
                transcriptStartIndex: transcriptStartIndex
            )
        )
    }

    private func recordLivePrompt(
        text: String,
        options: GenerationOptions,
        responseFormatName: String?,
        turnIndex: Int,
        spanName: String
    ) {
        let payload = FMPromptPayload(
            content: FMRedactedText(text, redaction: configuration.redaction.promptContent, redactor: configuration.redaction.redactor),
            options: FMGenerationOptionsSnapshot(bridging: options),
            responseFormatName: responseFormatName,
            turnIndex: turnIndex
        )
        let delivered = context.record(.prompt(payload), spanPath: [spanName])
        if delivered {
            context.markPromptRecorded(turn: turnIndex)
        }
    }

    func reconcileStreamTurn(transcriptStartIndex: Int, turnIndex: Int) {
        reconcile(entries: base.transcript[transcriptStartIndex...], startingTurnIndex: turnIndex)
    }

    func recordStreamFailure(_ error: any Error, turnIndex: Int, turnSpanName: String, transcriptStartIndex: Int) {
        context.record(
            .generationError(FMGenerationErrorPayload(
                error: error, turnIndex: turnIndex, redaction: configuration.redaction
            )),
            spanPath: [turnSpanName]
        )
        reconcile(entries: base.transcript[transcriptStartIndex...], startingTurnIndex: turnIndex)
    }

    /// Records the transcript-derived events for a slice, skipping copies
    /// recorded live: prompts by turn number, tool events by
    /// (kind, turn, toolName, invocationIndex), everything by transcript
    /// entry id. Every consumed entry id is then remembered so
    /// `recordProvenance()` never double-records.
    @discardableResult
    private func reconcile(
        entries: some Sequence<Transcript.Entry>,
        startingTurnIndex: Int
    ) -> (events: Int, turns: Int, toolCalls: Int, skippedSegments: Int) {
        let entryArray = Array(entries)
        guard !entryArray.isEmpty else { return (0, 0, 0, 0) }
        // No deliverable run => record nothing AND mark nothing, so every
        // entry stays eligible for a later recordProvenance() backfill.
        // Delivery is uniform across one reconcile pass (same task, same
        // captured handle), so a single up-front probe is sound.
        guard context.canDeliverNow() else { return (0, 0, 0, 0) }

        let bridged = FMTranscriptBridge.bridge(entryArray)
        let mapper = FMSnapshotMapper(configuration: configuration)
        let mapped = mapper.mapWithOrigins(
            bridged.snapshot,
            in: 0..<bridged.snapshot.entries.count,
            startingTurnIndex: startingTurnIndex
        )

        var events = 0
        var turns = 0
        var toolCalls = 0
        for item in mapped {
            guard !context.isEntryRecorded(entryArray[item.entryIndex].id) else { continue }
            switch item.event.payload {
            case .prompt(let payload):
                guard !context.promptWasRecordedLive(turn: payload.turnIndex) else { continue }
                turns += 1
            case .toolCall(let payload):
                guard !context.hasLiveToolEvent(
                    kind: "call", turn: payload.turnIndex,
                    toolName: payload.toolName, invocation: payload.invocationIndex
                ) else { continue }
                toolCalls += 1
            case .toolOutput(let payload):
                guard !context.hasLiveToolEvent(
                    kind: "output", turn: payload.turnIndex,
                    toolName: payload.toolName, invocation: payload.invocationIndex
                ) else { continue }
            default:
                break
            }
            context.record(item.event.payload, spanPath: item.event.spanPath)
            events += 1
        }
        context.markEntriesRecorded(entryArray.map(\.id))
        return (events, turns, toolCalls, bridged.skippedSegmentCount)
    }
}
#endif
#endif  // compiler(>=6.2)
