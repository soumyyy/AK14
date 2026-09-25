import Foundation

/// Versioned thresholds and weights for clustering, junk filtering, ranking and diversity.
/// Distances are Vision feature-print distances (calibrated on real data: unrelated photos ≈ 1.0).
public struct ReductionConfig: Codable, Sendable, Equatable {
    public var version = "reduction-1"
    public var dupDistance = 0.10
    public var dupSeconds = 90.0
    public var shotDistance = 0.30
    public var shotSeconds = 600.0
    public var maxClusterSpanSeconds = 900.0
    public var neighbourWindow = 12
    /// Sharpness value treated as "fully sharp" when normalizing to 0...1.
    public var sharpReference = 0.15
    public var weights = Weights()
    public var explorationFraction = 0.2
    public var triageMaxAdjustment = 0.2
    /// Distance at which two photos count as fully dissimilar for redundancy.
    public var similarityHorizon = 0.6

    public struct Weights: Codable, Sendable, Equatable {
        public var usability = 0.25, people = 0.15, saliency = 0.15, aesthetic = 0.10
        public var semantic = 0.15, distinctiveness = 0.10, userSignal = 0.10
    }

    public init() {}

    public func sharp01(_ f: PhotoFeatures?) -> Double? {
        f?.sharpness.map { min(1, $0 / sharpReference) }
    }

    /// 0.5·sharpness + 0.3·face quality (0.5 when no faces) + 0.2·aesthetic, used to pick cluster representatives.
    public func technicalScore(_ f: PhotoFeatures?) -> Double {
        let sharp = sharp01(f) ?? 0.5
        let qualities = f?.faces.compactMap(\.captureQuality) ?? []
        let face = qualities.isEmpty ? 0.5 : qualities.reduce(0, +) / Double(qualities.count)
        let aesthetic = f?.aestheticScore.map { ($0 + 1) / 2 } ?? 0.5
        return 0.5 * sharp + 0.3 * face + 0.2 * aesthetic
    }
}

public enum ReductionTargets {
    /// Spec §5.1 adaptive counts, clamped to the number of usable representatives.
    public static func forUsable(_ n: Int) -> (triage: Int, planning: ClosedRange<Int>) {
        let (triage, planning): (Int, ClosedRange<Int>) =
            n < 50 ? (n, 20...40) : n <= 200 ? (60, 25...45) : n <= 600 ? (70, 30...50) : (90, 35...60)
        let t = min(triage, n)
        let lo = min(planning.lowerBound, t), hi = min(planning.upperBound, t)
        return (t, lo...max(lo, hi))
    }
}
