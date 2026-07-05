import Foundation

/// Codable projection of FoundationModels' `GenerationOptions`, which is
/// verified NOT Codable in the SDK.
///
/// `SamplingMode` has no accessors: the bridge can only compare against
/// `.greedy` via `==`, so a non-nil, non-greedy mode maps to `.random` and its
/// parameters (k / probability threshold / seed) are unrecoverable.
public struct FMGenerationOptionsSnapshot: Codable, Sendable, Equatable {
    public enum Sampling: String, Codable, Sendable, Equatable {
        case unspecified, greedy, random
    }

    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var sampling: Sampling

    public init(
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        sampling: Sampling = .unspecified
    ) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.sampling = sampling
    }
}
