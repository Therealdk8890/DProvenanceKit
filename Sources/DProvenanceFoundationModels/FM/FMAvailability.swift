#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FMModelAvailabilityPayload {
    public init(model: SystemLanguageModel) {
        switch model.availability {
        case .available:
            self.init(isAvailable: true, unavailableReason: nil, contextSize: model.contextSize)
        case .unavailable(let reason):
            self.init(
                isAvailable: false,
                unavailableReason: Self.reasonIdentifier(reason),
                contextSize: model.contextSize
            )
        }
    }

    /// `UnavailableReason` is non-frozen: unknown future reasons map to
    /// "unknown" rather than crashing; the payload's reason strings are part
    /// of the frozen wire contract.
    static func reasonIdentifier(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device_not_eligible"
        case .appleIntelligenceNotEnabled: return "apple_intelligence_not_enabled"
        case .modelNotReady: return "model_not_ready"
        @unknown default: return "unknown"
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension SystemLanguageModel {
    /// Records an fm_model_availability event into the ambient run and
    /// returns `isAvailable`, so callers can gate generation on the same
    /// check they trace.
    @discardableResult
    public func recordAvailability(configuration: FMTracingConfiguration = .default) -> Bool {
        let payload = FMModelAvailabilityPayload(model: self)
        configuration.record(.modelAvailability(payload))
        return payload.isAvailable
    }
}
#endif
