import Foundation

/// A diagnostic layer used strictly for stability testing and CI boundary validation.
///
/// It perturbs the **equivalence evaluator** (the function that actually drives alignment
/// decisions), not the observability callback. Injecting noise into equivalence scores can
/// flip pairs across the matching threshold, which changes the engine's findings and therefore
/// the measured precision/recall/F1 across stability iterations. (An earlier version perturbed
/// only the meta-event callback, which is observational and cannot move F1 — so it could not
/// actually demonstrate anything.)
///
/// The perturbation is GATED by the `DeterministicBoundary`: when the boundary declares the
/// environment cache-isolated, the base evaluator is returned unchanged (fully deterministic).
/// Only when isolation is lifted does noise flow in. That gating is precisely what lets a
/// stability run show the boundary is load-bearing: isolated => zero variance; not isolated =>
/// variance the stability report can detect.
public struct EvaluationPerturbationLayer: Sendable {

    public enum PerturbationMode: Sendable {
        /// Fully deterministic, passthrough.
        case none
        /// Randomly shifts equivalence scores by +/- `amplitude`.
        case scoreNoise(amplitude: Double)
    }

    public let mode: PerturbationMode

    public init(mode: PerturbationMode) {
        self.mode = mode
    }

    /// Returns an equivalence evaluator that may inject score noise to simulate engine
    /// non-determinism, gated by the deterministic boundary.
    public func evaluator<T: TraceableEvent>(
        wrapping base: AnyEquivalenceEvaluator<T>,
        boundary: DeterministicBoundary
    ) -> AnyEquivalenceEvaluator<T> {
        guard case let .scoreNoise(amplitude) = mode, boundary.cacheIsolated == false, amplitude > 0 else {
            // Isolated (or no perturbation): deterministic passthrough.
            return base
        }
        return AnyEquivalenceEvaluator<T>(
            identifier: base.evaluatorIdentifier + "+noise",
            evaluator: { a, b in
                let s = base.evaluateSimilarity(base: a, comparison: b)
                let noise = Double.random(in: -amplitude...amplitude)
                return max(0.0, min(1.0, s + noise))
            },
            ambiguityThresholdFn: { e in base.ambiguityThreshold(for: e) }
        )
    }
}
