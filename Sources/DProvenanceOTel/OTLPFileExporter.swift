import Foundation
import DProvenanceKit

/// Writes one OTLP/JSON document per export to a fixed destination.
///
/// Byte-stable re-exports require: identical runs in identical order, same
/// options (incl. the dropStats snapshot), same OS/Foundation version
/// (Double formatting is stable per Foundation release, not across them).
public struct OTLPFileExporter<T: TraceableEvent>: OTelTraceExporter, Sendable {
    private let destination: URL
    private let mapper: OTelSpanMapper<T>
    private let deterministic: Bool

    public init(destination: URL,
                options: OTelExportOptions<T> = .init(),
                deterministic: Bool = true) {
        self.destination = destination
        self.mapper = OTelSpanMapper(options: options)
        self.deterministic = deterministic
    }

    public func export(_ runs: [TraceRun<T>]) async throws -> OTelExportReceipt {
        let mapped = mapper.mapped(for: runs)

        let data: Data
        do {
            data = try OTLPJSON.encode(mapped.document, deterministic: deterministic)
        } catch {
            throw OTelExportError.encodingFailed(description: String(describing: error))
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw OTelExportError.fileWriteFailed(
                path: destination.path,
                description: String(describing: error)
            )
        }

        return OTelExportReceipt(
            runsExported: mapped.runsExported,
            runsSkipped: mapped.runsSkipped,
            spanCount: mapped.spanCount,
            spanEventCount: mapped.spanEventCount,
            encodedBytes: data.count,
            traceIDsByRun: mapped.traceIDsByRun
        )
    }
}
