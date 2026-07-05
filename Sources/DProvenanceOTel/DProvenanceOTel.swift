// DProvenanceOTel
//
// Zero-dependency OTLP/JSON export bridge: turns DProvenanceKit trace runs into
// OTLP/JSON documents for OTLP/HTTP backends. One `TraceRun` becomes one OTel
// trace (a root span plus child spans); ids are derived deterministically from
// DPK identifiers so the same run always maps to the same trace, and re-exports
// are byte-identical (see `OTelSpanMapper` for the exact scope of that claim).
//
// Backend support matrix — OTLP/JSON is a first-class OTLP encoding, but
// per-backend acceptance varies:
//
//   Langfuse         YES — accepts OTLP HTTP/JSON directly (cloud, all regions,
//                    and self-hosted >= v3.22.0). Use `Configuration.langfuse`.
//                    Regions: default cloud.langfuse.com is EU;
//                    us.cloud.langfuse.com is US; jp.cloud.langfuse.com is
//                    Japan; hipaa.cloud.langfuse.com is HIPAA.
//   otel-collector   YES — the stock collector's OTLP/HTTP receiver accepts
//                    JSON. Use `Configuration.collector`.
//   Arize Phoenix    NO — its /v1/traces handler returns HTTP 415 for any
//                    Content-Type other than application/x-protobuf. Reach
//                    Phoenix through an otel-collector relay that re-encodes:
//
//                        receivers:
//                          otlp:
//                            protocols:
//                              http:            # accepts this exporter's JSON
//                        exporters:
//                          otlp/phoenix:
//                            endpoint: phoenix:4317   # protobuf out
//                        service:
//                          pipelines:
//                            traces:
//                              receivers: [otlp]
//                              exporters: [otlp/phoenix]
//
//                    The same relay recipe is the universal fallback for any
//                    backend that rejects OTLP/JSON.
//
// CryptoKit is used for ID derivation, consistent with the core target's
// existing CryptoKit usage.

import Foundation
import DProvenanceKit

/// Module identity, stamped into every exported document's instrumentation
/// scope so backends can attribute spans to this bridge.
public enum OTelBridge {
    public static let scopeName = "dprovenancekit-otel"
    public static let version = "0.1.0"

    /// Version tag of the deterministic ID derivation scheme (`OTelTraceIdentity`).
    /// Bumping it changes every derived trace/span id, so it only moves when the
    /// preimage format changes — never for ordinary releases.
    public static let idSchemeVersion = "v1"
}
