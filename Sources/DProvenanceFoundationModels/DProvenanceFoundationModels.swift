// DProvenanceFoundationModels
//
// Auto-instrumentation of Apple's FoundationModels framework: captures
// on-device LLM prompts, responses, and tool calls as DProvenanceKit traces.
//
// ## Adoption one-liners
//
// Post-hoc (zero refactor, after any existing FoundationModels code):
//
//     session.recordProvenance()
//
// Greenfield (live capture, tools traced as child spans):
//
//     let session = LanguageModelSession.traced(instructions: "Be terse.")
//
// Standalone tool tracing without a traced session:
//
//     let tool = WeatherTool().traced()
//
// ## Frozen contracts
//
// The following are locked by golden tests and MUST NOT change. Payload
// evolution is additive-optional-fields only; new semantics require a new
// typeIdentifier.
//
// | typeIdentifier          | priority    |
// |-------------------------|-------------|
// | fm_instructions         | .structural |
// | fm_prompt               | .critical   |
// | fm_tool_call            | .critical   |
// | fm_tool_output          | .structural |
// | fm_response             | .critical   |
// | fm_generation_error     | .critical   |
// | fm_model_availability   | .diagnostic |
// | fm_stream_snapshot      | .telemetry  |
// | fm_unknown_entry        | .diagnostic |
//
// fm_prompt/fm_response/fm_tool_call/fm_generation_error are .critical because
// the TraceAlignmentEngine's headline regression rule (removed or reordered
// steps => RegressionRisk.high) fires only on .critical events.
//
// ## Span-path grammar (frozen, see FMSpanPath)
//
//     fm.turn.<i>                                  turn span (0-based)
//     fm.turn.<i>.tool.<toolName>.<k>              k-th call of toolName in turn i
//     fm.tool.<toolName>.<k>                       standalone TracedTool invocation
//     fm[<label>].turn.<i>                         with a session label prefix
//
// Span ids ARE these strings: same behavior => same strings => parentSpanID
// matches across runs, which is what the alignment engine's structural term
// compares.
//
// ## Parity invariant
//
// Payloads carry NO volatile data: no transcript entry ids, no call ids, no
// timestamps, no UUIDs. The envelope owns time; linkage is
// (turnIndex, invocationIndex). Consequence: live capture and post-hoc
// ingestion of the same transcript produce byte-exact equal payloads.
//
// ## Privacy
//
// The default redaction policy is `.full` — on-device capture is the point.
// If traces leave the device (SQLite exports, Cloud stores), use
// `FMRedactionPolicy.hashed`: content equality still works cross-policy
// because FMRedactedText identity is (sha256, utf8Count).
//
// ## Longevity / promotion plan (not built now)
//
// fm_* identifiers are frozen and honest: payloads mirror FM-specific
// semantics. When a second on-device provider becomes real, the ungated layer
// (snapshot IR, redaction, mapper, recorder, span grammar) is the seam:
// extract it into a DProvenanceGenAI target informed by two real providers
// and re-export from here via @_exported import — zero source or identifier
// breakage. Cross-provider diffing, if ever needed, is delivered at the
// AnyTraceableEvent level at that time, not by pre-emptively neutral
// identifiers over provider-shaped payloads.

// One-import ergonomics. Documented fallback: if the underscored attribute
// ever goes away, consumers add a plain `import DProvenanceKit`.
@_exported import DProvenanceKit

/// The typed trace namespace for FoundationModels events:
/// `FMTrace.run(contextID:store:) { ... }`.
public typealias FMTrace = DProvenanceKit<FoundationModelTraceEvent>

/// Frozen typeIdentifier constants. Never renamed or reused; additions only.
public enum FMEventType {
    public static let instructions = "fm_instructions"
    public static let prompt = "fm_prompt"
    public static let toolCall = "fm_tool_call"
    public static let toolOutput = "fm_tool_output"
    public static let response = "fm_response"
    public static let generationError = "fm_generation_error"
    public static let modelAvailability = "fm_model_availability"
    public static let streamSnapshot = "fm_stream_snapshot"
    public static let unknownEntry = "fm_unknown_entry"
}
