import Foundation
import DProvenanceKit

/// Pure, non-throwing, deterministic mapper from DPK trace runs to OTLP spans
/// (mapping rules M1–M9).
///
/// Structural invariants the mapper guarantees:
/// - The output is always a tree rooted at the root span — nothing dangles.
///   DPK spans exist only as `(spanID, parentSpanID)` stamps on member events,
///   so a wrapper `withSpan` that recorded nothing appears only in its
///   children's `parentSpanID`; such spans are SYNTHESIZED (`dpk.synthesized`)
///   rather than treated as orphans, preserving the recorded nesting.
///   Self-parents, member disagreement, and hand-assembled cycles are broken
///   deterministically and flagged `dpk.parent_conflict` (M4).
/// - Output ordering never depends on `Dictionary` iteration (which is seeded
///   per process launch): root first, then spans by min sequence over
///   members-or-descendants (ties: spanId hex), span events by sequence,
///   attributes in the fixed orders of M8/M9 (M7).
/// - Never throws: a payload that fails re-encoding yields
///   `dpk.payload_error = "encoding_failed"` instead (M8), mirroring DPK's
///   record-never-throws philosophy.
///
/// Byte-stability scope: identical input runs + same options (including the
/// dropStats snapshot) + same OS/Foundation version (Double formatting).
public struct OTelSpanMapper<T: TraceableEvent>: Sendable {
    public let options: OTelExportOptions<T>

    public init(options: OTelExportOptions<T> = .init()) {
        self.options = options
    }

    /// One resource + one scope; each non-empty run contributes one trace.
    /// Implements mapping rules M1–M9, including synthesized parents,
    /// parent-conflict/cycle resolution, GenAI promotion, and the total
    /// ordering contract (M7). Never throws (M8 payload-error path).
    public func document(for runs: [TraceRun<T>]) -> OTLPTraceDocument {
        mapped(for: runs).document
    }

    /// Single-run building block; empty for a zero-event run.
    public func spans(for run: TraceRun<T>) -> [OTLPSpan] {
        guard !run.events.isEmpty else { return [] }

        // Sequence is the authoritative causal clock; sorting here makes the
        // mapping insensitive to the input array's order (M7).
        let events = run.events.sorted { $0.sequence < $1.sequence }

        let traceId = OTelTraceIdentity.traceID(forRun: run.runID)
        let rootSpanId = OTelTraceIdentity.rootSpanID(forRun: run.runID)

        // M6 semantics resolution: conformance beats closure; `otelEventName`
        // only exists on the conformance.
        let resolved: [ResolvedEvent] = events.map { event in
            let conformance = event.payload as? any OTelSemanticsProviding
            let semantics = conformance?.otelSemantics ?? options.semanticAttributes?(event)
            return ResolvedEvent(
                event: event,
                semantics: semantics,
                eventName: conformance?.otelEventName,
                promoted: semantics != nil && options.genAIPromotion == .dedicatedChildSpan
            )
        }

        // M3 grouping. `groupOrder` preserves first-appearance (= sequence)
        // order so every later iteration over groups is deterministic.
        var groupOrder: [String] = []
        var membersByID: [String: [ResolvedEvent]] = [:]
        var rootMembers: [ResolvedEvent] = []
        for r in resolved {
            if let spanID = r.event.spanID {
                if membersByID[spanID] == nil { groupOrder.append(spanID) }
                membersByID[spanID, default: []].append(r)
            } else {
                rootMembers.append(r)
            }
        }

        // M4 parent resolution: lowest-sequence member's parentSpanID wins.
        var groups: [String: Group] = [:]
        for id in groupOrder {
            let members = membersByID[id]!
            let original = members[0].event.parentSpanID
            var conflict = members.contains { $0.event.parentSpanID != original }
            var parent = original
            if parent == id {
                parent = nil
                conflict = true
            }
            groups[id] = Group(dpkSpanID: id, members: members,
                               originalParent: original, resolvedParent: parent,
                               conflict: conflict)
        }

        // M3 synthesis: resolved parents with no member events become
        // placeholder spans parented to root — their true parent is
        // unrecorded in DPK's model and unknowable.
        var synthesizedIDs: [String] = []
        var synthesizedSet: Set<String> = []
        for id in groupOrder {
            guard let parent = groups[id]!.resolvedParent,
                  membersByID[parent] == nil,
                  !synthesizedSet.contains(parent) else { continue }
            synthesizedIDs.append(parent)
            synthesizedSet.insert(parent)
        }

        // M4 cycle break: possible only in hand-assembled input (the TaskLocal
        // recorder cannot produce one), but a cycle would hang the bottom-up
        // time pass, so it must be broken before the envelope computation.
        breakCycles(in: &groups, order: groupOrder, synthesized: synthesizedSet)

        // Children lists for the bottom-up passes, in deterministic order.
        var childGroupsOf: [String: [String]] = [:]
        var rootChildGroups: [String] = []
        for id in groupOrder {
            if let parent = groups[id]!.resolvedParent {
                childGroupsOf[parent, default: []].append(id)
            } else {
                rootChildGroups.append(id)
            }
        }

        // M5/M7 bottom-up envelopes: bounds = member events UNION descendant
        // spans; order key = min sequence over members-or-descendants.
        var envelopes: [String: Envelope] = [:]
        func envelope(for id: String) -> Envelope {
            if let cached = envelopes[id] { return cached }
            var env = Envelope()
            if let group = groups[id] {
                for member in group.members {
                    env.include(time: member.event.timestamp, sequence: member.event.sequence)
                }
            }
            for child in childGroupsOf[id] ?? [] {
                env.merge(envelope(for: child))
            }
            envelopes[id] = env
            return env
        }
        for id in groupOrder { _ = envelope(for: id) }
        for id in synthesizedIDs { _ = envelope(for: id) }

        // Root bounds = min/max over ALL events in the run (M5) — the root can
        // legitimately have zero direct members when everything lives in spans.
        var rootEnvelope = Envelope()
        for event in events {
            rootEnvelope.include(time: event.timestamp, sequence: event.sequence)
        }

        var output: [Placed] = []

        output.append(Placed(
            orderKey: 0,
            spanIdHex: rootSpanId,
            isRoot: true,
            span: rootSpan(run: run, events: events, rootMembers: rootMembers,
                           traceId: traceId, rootSpanId: rootSpanId,
                           envelope: rootEnvelope)
        ))

        for id in groupOrder {
            let group = groups[id]!
            let env = envelopes[id] ?? rootEnvelope
            let spanId = OTelTraceIdentity.spanID(forRun: run.runID, dpkSpanID: id)
            output.append(Placed(
                orderKey: env.minSequence,
                spanIdHex: spanId,
                isRoot: false,
                span: childSpan(group: group, run: run, traceId: traceId,
                                rootSpanId: rootSpanId, spanId: spanId, envelope: env)
            ))
        }

        for id in synthesizedIDs {
            let env = envelopes[id] ?? rootEnvelope
            let spanId = OTelTraceIdentity.spanID(forRun: run.runID, dpkSpanID: id)
            output.append(Placed(
                orderKey: env.minSequence,
                spanIdHex: spanId,
                isRoot: false,
                span: synthesizedSpan(dpkSpanID: id, traceId: traceId,
                                      rootSpanId: rootSpanId, spanId: spanId, envelope: env)
            ))
        }

        // M6 promotion: the event MOVES to its own child span (it is excluded
        // from span-event emission below), parented to its containing span.
        for r in resolved where r.promoted {
            let parentSpanId: String
            if let containing = r.event.spanID {
                parentSpanId = OTelTraceIdentity.spanID(forRun: run.runID, dpkSpanID: containing)
            } else {
                parentSpanId = rootSpanId
            }
            let spanId = OTelTraceIdentity.eventSpanID(forRun: run.runID, sequence: r.event.sequence)
            output.append(Placed(
                orderKey: r.event.sequence,
                spanIdHex: spanId,
                isRoot: false,
                span: promotedSpan(r, traceId: traceId, parentSpanId: parentSpanId, spanId: spanId)
            ))
        }

        // M7 total order: root first; everything else by (min sequence over
        // members-or-descendants, spanId hex).
        output.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.orderKey != b.orderKey { return a.orderKey < b.orderKey }
            return a.spanIdHex < b.spanIdHex
        }
        return output.map(\.span)
    }

    // MARK: - Internal mapping product (feeds exporter receipts)

    struct MappedRuns {
        var document: OTLPTraceDocument
        var runsExported: Int
        var runsSkipped: Int
        var spanCount: Int
        var spanEventCount: Int
        var traceIDsByRun: [UUID: String]
    }

    func mapped(for runs: [TraceRun<T>]) -> MappedRuns {
        var allSpans: [OTLPSpan] = []
        var runsExported = 0
        var runsSkipped = 0
        var traceIDsByRun: [UUID: String] = [:]

        // Runs stay in caller order (M7); the store convenience is
        // responsible for sorting store-supplied runs.
        for run in runs {
            let runSpans = spans(for: run)
            guard !runSpans.isEmpty else {
                runsSkipped += 1
                continue
            }
            runsExported += 1
            traceIDsByRun[run.runID] = OTelTraceIdentity.traceID(forRun: run.runID)
            allSpans.append(contentsOf: runSpans)
        }

        let document = OTLPTraceDocument(resourceSpans: [
            OTLPResourceSpans(
                resource: OTLPResource(attributes: resourceAttributes()),
                scopeSpans: [
                    OTLPScopeSpans(
                        scope: OTLPScope(name: OTelBridge.scopeName, version: OTelBridge.version),
                        spans: allSpans
                    )
                ]
            )
        ])
        return MappedRuns(
            document: document,
            runsExported: runsExported,
            runsSkipped: runsSkipped,
            spanCount: allSpans.count,
            spanEventCount: allSpans.reduce(0) { $0 + $1.events.count },
            traceIDsByRun: traceIDsByRun
        )
    }

    // MARK: - Private structure

    private struct ResolvedEvent {
        let event: TraceEvent<T>
        let semantics: GenAIAttributes?
        let eventName: String?
        let promoted: Bool
    }

    private struct Group {
        let dpkSpanID: String
        let members: [ResolvedEvent]        // ascending sequence
        let originalParent: String?         // lowest-sequence member's claim
        var resolvedParent: String?         // nil = root
        var conflict: Bool
    }

    /// Time/order accumulator for one span's members-union-descendants pass.
    private struct Envelope {
        var start: Date = .distantFuture
        var end: Date = .distantPast
        var minSequence: UInt64 = .max

        mutating func include(time: Date, sequence: UInt64) {
            if time < start { start = time }
            if time > end { end = time }
            if sequence < minSequence { minSequence = sequence }
        }

        mutating func merge(_ other: Envelope) {
            if other.start < start { start = other.start }
            if other.end > end { end = other.end }
            if other.minSequence < minSequence { minSequence = other.minSequence }
        }

        /// End clamped >= start (M5); a single-event childless span collapses
        /// to start == end.
        var clamped: (start: Date, end: Date) {
            (start, max(start, end))
        }
    }

    private struct Placed {
        let orderKey: UInt64
        let spanIdHex: String
        let isRoot: Bool
        let span: OTLPSpan
    }

    /// Walks every group's parent chain with a visited set; any chain that
    /// never reaches root contains a cycle, broken by reparenting the cycle
    /// member with the lowest min member sequence to root (M4). Repeats until
    /// every chain terminates — each pass removes one cycle, so this is
    /// bounded by the group count.
    private func breakCycles(in groups: inout [String: Group],
                             order: [String],
                             synthesized: Set<String>) {
        while true {
            var cycle: [String]? = nil
            outer: for start in order {
                var path: [String] = []
                var onPath = Set<String>()
                var current: String? = start
                while let id = current, groups[id] != nil {
                    if onPath.contains(id) {
                        let first = path.firstIndex(of: id)!
                        cycle = Array(path[first...])
                        break outer
                    }
                    path.append(id)
                    onPath.insert(id)
                    current = groups[id]!.resolvedParent
                }
            }
            guard let cycle else { return }
            let victim = cycle.min { a, b in
                groups[a]!.members[0].event.sequence < groups[b]!.members[0].event.sequence
            }!
            groups[victim]!.resolvedParent = nil
            groups[victim]!.conflict = true
        }
    }

    // MARK: - Span construction

    private func rootSpan(run: TraceRun<T>, events: [TraceEvent<T>],
                          rootMembers: [ResolvedEvent],
                          traceId: String, rootSpanId: String,
                          envelope: Envelope) -> OTLPSpan {
        var name = options.rootSpanName(run)
        if name.isEmpty {
            name = "run " + traceId.prefix(8)
        }

        var attributes: [OTLPKeyValue] = [
            .string(DPKOTelAttribute.runID, run.runID.uuidString),
            .string(DPKOTelAttribute.contextID, run.contextID),
            .int(DPKOTelAttribute.schemaVersion, Int64(clamping: events[0].schemaVersion)),
            .int(DPKOTelAttribute.eventCount, Int64(clamping: events.count)),
        ]
        if let stats = options.dropStats {
            attributes.append(.bool(DPKOTelAttribute.preservedIntegrity, stats.preservedIntegrity))
        }

        let bounds = envelope.clamped
        return OTLPSpan(
            traceId: traceId,
            spanId: rootSpanId,
            parentSpanId: nil,
            name: name,
            kind: .internal,
            startTimeUnixNano: OTLPTimestamp.unixNano(bounds.start),
            endTimeUnixNano: OTLPTimestamp.unixNano(bounds.end),
            attributes: attributes,
            events: rootMembers.filter { !$0.promoted }.map(spanEvent(for:)),
            status: options.rootStatus?(run) ?? .unset
        )
    }

    private func childSpan(group: Group, run: TraceRun<T>, traceId: String,
                           rootSpanId: String, spanId: String,
                           envelope: Envelope) -> OTLPSpan {
        let parentSpanId: String
        if let parent = group.resolvedParent {
            parentSpanId = OTelTraceIdentity.spanID(forRun: run.runID, dpkSpanID: parent)
        } else {
            parentSpanId = rootSpanId
        }

        // dpk.span_id / dpk.parent_span_id carry the ORIGINAL DPK identifiers:
        // the display name is overridable and the OTel parent link reflects
        // conflict resolution, so these are the only recovery path back to
        // what was recorded.
        var attributes: [OTLPKeyValue] = [
            .string(DPKOTelAttribute.spanID, group.dpkSpanID)
        ]
        if let original = group.originalParent {
            attributes.append(.string(DPKOTelAttribute.parentSpanID, original))
        }
        let engines = Set(group.members.map { $0.event.engineName })
        if engines.count == 1, let engine = engines.first {
            attributes.append(.string(DPKOTelAttribute.engine, engine))
        }
        if group.conflict {
            attributes.append(.bool(DPKOTelAttribute.parentConflict, true))
        }

        // If an error event is attached to this span (rather than promoted to its
        // own span), the containing span should still surface the failure. Use the
        // first error member in sequence order for a deterministic status.
        let errorType = group.members
            .first { !$0.promoted && $0.semantics?.errorType != nil }?
            .semantics?.errorType

        let bounds = envelope.clamped
        return OTLPSpan(
            traceId: traceId,
            spanId: spanId,
            parentSpanId: parentSpanId,
            name: options.childSpanName(group.dpkSpanID),
            kind: .internal,
            startTimeUnixNano: OTLPTimestamp.unixNano(bounds.start),
            endTimeUnixNano: OTLPTimestamp.unixNano(bounds.end),
            attributes: attributes,
            events: group.members.filter { !$0.promoted }.map(spanEvent(for:)),
            status: errorType.map(OTLPStatus.error) ?? .unset
        )
    }

    private func synthesizedSpan(dpkSpanID: String, traceId: String,
                                 rootSpanId: String, spanId: String,
                                 envelope: Envelope) -> OTLPSpan {
        let bounds = envelope.clamped
        return OTLPSpan(
            traceId: traceId,
            spanId: spanId,
            parentSpanId: rootSpanId,
            name: options.childSpanName(dpkSpanID),
            kind: .internal,
            startTimeUnixNano: OTLPTimestamp.unixNano(bounds.start),
            endTimeUnixNano: OTLPTimestamp.unixNano(bounds.end),
            attributes: [
                .string(DPKOTelAttribute.spanID, dpkSpanID),
                .bool(DPKOTelAttribute.synthesized, true),
            ],
            events: [],
            status: .unset
        )
    }

    private func promotedSpan(_ r: ResolvedEvent, traceId: String,
                              parentSpanId: String, spanId: String) -> OTLPSpan {
        let semantics = r.semantics ?? GenAIAttributes()
        let isToolOp = semantics.operationName == GenAISemconvAttribute.executeToolOperation

        let name: String
        if let explicit = r.eventName {
            name = explicit
        } else if let op = semantics.operationName, let model = semantics.requestModel {
            name = "\(op) \(model)"
        } else if isToolOp, let tool = semantics.toolName {
            name = "\(GenAISemconvAttribute.executeToolOperation) \(tool)"
        } else {
            name = semantics.operationName ?? r.event.payload.typeIdentifier
        }

        let time = OTLPTimestamp.unixNano(r.event.timestamp)
        return OTLPSpan(
            traceId: traceId,
            spanId: spanId,
            parentSpanId: parentSpanId,
            name: name,
            kind: isToolOp ? .internal : .client,
            startTimeUnixNano: time,
            endTimeUnixNano: time,
            attributes: semantics.keyValues + eventEnvelopeAttributes(for: r.event),
            events: [],
            // A generation/tool span that carries an error type is a failure;
            // marking it ERROR is what lets error-rate dashboards see it.
            status: semantics.errorType.map(OTLPStatus.error) ?? .unset
        )
    }

    // MARK: - Span events and attributes

    private func spanEvent(for r: ResolvedEvent) -> OTLPSpanEvent {
        // With .attachedToEventOnly the gen_ai set leads, mirroring the
        // promoted-span attribute order (M6).
        var attributes: [OTLPKeyValue] = []
        if let semantics = r.semantics, options.genAIPromotion == .attachedToEventOnly {
            attributes.append(contentsOf: semantics.keyValues)
        }
        attributes.append(contentsOf: eventEnvelopeAttributes(for: r.event))
        return OTLPSpanEvent(
            timeUnixNano: OTLPTimestamp.unixNano(r.event.timestamp),
            name: r.eventName ?? r.event.payload.typeIdentifier,
            attributes: attributes
        )
    }

    /// The full dpk.* event envelope (M8), fixed order: type_identifier,
    /// sequence, priority, engine, then the payload policy's attributes.
    private func eventEnvelopeAttributes(for event: TraceEvent<T>) -> [OTLPKeyValue] {
        var attributes: [OTLPKeyValue] = [
            .string(DPKOTelAttribute.typeIdentifier, event.payload.typeIdentifier),
            .int(DPKOTelAttribute.sequence, Int64(clamping: event.sequence)),
            .string(DPKOTelAttribute.priority, priorityName(event.payload.priority)),
            .string(DPKOTelAttribute.engine, event.engineName),
        ]
        attributes.append(contentsOf: payloadAttributes(for: event.payload))
        return attributes
    }

    private func priorityName(_ priority: TracePriority) -> String {
        switch priority {
        case .telemetry: return "telemetry"
        case .diagnostic: return "diagnostic"
        case .structural: return "structural"
        case .critical: return "critical"
        }
    }

    /// M8 payload policy. Re-encoding uses DEFAULT `JSONEncoder` strategies to
    /// match DPK's SQLite persistence (Dates inside payloads render as
    /// reference-date doubles either way); only `.sortedKeys` output
    /// formatting is added, because Foundation otherwise randomizes object
    /// key order per encode, which would break the M7 byte-stability
    /// contract. The mapper never throws: an encode failure — a real path,
    /// DPK's own record tallies them into dropStats — yields
    /// `dpk.payload_error = "encoding_failed"`.
    private func payloadAttributes(for payload: T) -> [OTLPKeyValue] {
        let maxBytes: Int?
        switch options.payloadInclusion {
        case .omitted:
            return []
        case .full:
            maxBytes = nil
        case .truncated(let bytes):
            maxBytes = bytes
        }

        let json: String
        do {
            json = try encodedPayloadJSON(payload)
        } catch {
            return [.string(DPKOTelAttribute.payloadError, "encoding_failed")]
        }

        guard let maxBytes else {
            return [.string(DPKOTelAttribute.payload, json)]
        }
        let (cut, didTruncate) = truncateUTF8(json, maxBytes: maxBytes)
        var attributes: [OTLPKeyValue] = [.string(DPKOTelAttribute.payload, cut)]
        if didTruncate {
            attributes.append(.bool(DPKOTelAttribute.payloadTruncated, true))
        }
        return attributes
    }

    private func encodedPayloadJSON(_ payload: T) throws -> String {
        if let erased = payload as? AnyTraceableEvent {
            return try inlinedJSON(for: erased)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// `AnyTraceableEvent` persists the real payload as an escaped JSON string
    /// inside `rawJSON`; inline it one level so backends show the actual
    /// object. Constructed manually (fixed key order = the struct's declared
    /// order) so the splice cannot disturb determinism. A `rawJSON` that is
    /// not itself valid JSON stays escaped — splicing it would corrupt the
    /// document.
    private func inlinedJSON(for erased: AnyTraceableEvent) throws -> String {
        let typeID = try jsonStringLiteral(erased.typeIdentifier)
        let rawData = Data(erased.rawJSON.utf8)
        let rawIsValidJSON = (try? JSONSerialization.jsonObject(
            with: rawData, options: [.fragmentsAllowed])) != nil
        let raw = rawIsValidJSON ? erased.rawJSON : try jsonStringLiteral(erased.rawJSON)
        return "{\"typeIdentifier\":\(typeID),\"priorityValue\":\(erased.priorityValue),\"rawJSON\":\(raw)}"
    }

    /// JSON string literal via a single-element array (top-level fragment
    /// encoding is not available on all supported OS versions).
    private func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode([value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Cuts on a UTF-8 boundary: backs off any continuation bytes at the cut
    /// point so the prefix is always well-formed.
    private func truncateUTF8(_ value: String, maxBytes: Int) -> (String, Bool) {
        let bytes = Array(value.utf8)
        guard bytes.count > maxBytes else { return (value, false) }
        var end = max(maxBytes, 0)
        while end > 0 && (bytes[end] & 0b1100_0000) == 0b1000_0000 {
            end -= 1
        }
        return (String(decoding: bytes[0..<end], as: UTF8.self), true)
    }

    // MARK: - Resource (M9)

    private func resourceAttributes() -> [OTLPKeyValue] {
        var attributes: [OTLPKeyValue] = [
            .string("service.name", options.serviceName),
            .string("telemetry.sdk.name", "dprovenancekit"),
            .string("telemetry.sdk.language", "swift"),
            .string("telemetry.sdk.version", OTelBridge.version),
        ]
        if let stats = options.dropStats {
            attributes.append(.int(DPKOTelAttribute.dropTelemetry, Int64(clamping: stats.telemetry)))
            attributes.append(.int(DPKOTelAttribute.dropDiagnostic, Int64(clamping: stats.diagnostic)))
            attributes.append(.int(DPKOTelAttribute.dropStructural, Int64(clamping: stats.structural)))
            attributes.append(.int(DPKOTelAttribute.dropCritical, Int64(clamping: stats.critical)))
            attributes.append(.int(DPKOTelAttribute.dropTotal, Int64(clamping: stats.total)))
            attributes.append(.bool(DPKOTelAttribute.preservedIntegrity, stats.preservedIntegrity))
        }
        attributes.append(contentsOf: options.resourceAttributes)
        return attributes
    }
}
