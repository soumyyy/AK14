import Foundation

/// Subtle carousel-wide colour correction toward the set's own centre (spec CS-8). Not a filter.
public enum CarouselGrade {
    nonisolated(unsafe) public static var gradeEnabled = true

    public static func adjustments(for ids: [AssetID], features: [AssetID: PhotoFeatures]) -> [AssetID: PhotoAdjustments] {
        let colored = ids.compactMap { id -> (AssetID, ColorProfile)? in
            guard let color = features[id]?.color else { return nil }
            return (id, color)
        }
        guard colored.count >= 3 else { return [:] }

        let targetL = median(colored.map(\.1.l))
        let targetWarmth = median(colored.map(\.1.warmth))
        let targetSat = median(colored.map(\.1.saturation))

        var out: [AssetID: PhotoAdjustments] = [:]
        for (id, color) in colored {
            let dL = targetL - color.l
            let dWarmth = targetWarmth - color.warmth
            let dSat = targetSat - color.saturation

            let exposure: Double
            if abs(dL) < 4 { exposure = 0 }
            else { exposure = clamp(0.4 * dL / 25, -0.35, 0.35) }

            let warmth: Double
            if abs(dWarmth) < 0.03 { warmth = 0 }
            else { warmth = clamp(0.4 * dWarmth * 2, -0.25, 0.25) }

            let saturation: Double
            if abs(dSat) < 0.04 { saturation = 0 }
            else { saturation = clamp(0.4 * dSat * 1.5, -0.15, 0.15) }

            if exposure == 0 && warmth == 0 && saturation == 0 { continue }
            out[id] = PhotoAdjustments(exposure: exposure, warmth: warmth, saturation: saturation)
        }
        return out
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}
