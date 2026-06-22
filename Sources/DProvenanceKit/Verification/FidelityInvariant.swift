import Foundation

public protocol FidelityInvariant: Sendable {
    func evaluate(_ map: FormalizationMap) -> Double
}
