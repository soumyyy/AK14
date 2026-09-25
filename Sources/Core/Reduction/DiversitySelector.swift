import Foundation

/// Greedy marginal-gain selection with soft time/people/scene coverage and a redundancy penalty,
/// then a bounded exploration fill that favours coverage over score (spec §5.3).
public enum DiversitySelector {
    public static func select(ranked: [RankedCandidate], target: Int, photos: [AssetID: PhotoRecord],
                              features: [AssetID: PhotoFeatures], distance: (AssetID, AssetID) -> Double?,
                              config: ReductionConfig) -> [RankedCandidate] {
        let target = min(target, ranked.count)
        guard target > 0 else { return [] }

        let bins = min(12, max(6, target / 8))
        let position = timePositions(ranked.compactMap { photos[$0.assetID] })
        /// Undated photos share one extra bin, so they can't each claim an "uncovered" time slot.
        func timeBin(_ id: AssetID) -> Int { position[id].map { min(bins - 1, Int($0 * Double(bins))) } ?? bins }
        func peopleBucket(_ id: AssetID) -> Int {
            let n = features[id]?.faces.count ?? 0
            return n == 0 ? 0 : n == 1 ? 1 : n <= 3 ? 2 : 3
        }
        func scene(_ id: AssetID) -> String { features[id]?.labels.first?.identifier ?? "unknown" }

        var remaining = ranked
        var selected: [RankedCandidate] = []
        var coveredBins = Set<Int>(), coveredPeople = Set<Int>(), coveredScenes = Set<String>()
        var maxSim: [AssetID: Double] = [:]

        func take(scoreWeight: Double, reason: String) {
            var bestIndex = 0, bestValue = -Double.infinity
            for (i, c) in remaining.enumerated() {
                let id = c.assetID
                let value = scoreWeight * c.effectiveScore
                    + (coveredBins.contains(timeBin(id)) ? 0 : 0.15)
                    + (coveredPeople.contains(peopleBucket(id)) ? 0 : 0.08)
                    + (coveredScenes.contains(scene(id)) ? 0 : 0.10)
                    - 0.25 * (maxSim[id] ?? 0)
                if value > bestValue || (value == bestValue && id < remaining[bestIndex].assetID) {
                    bestValue = value; bestIndex = i
                }
            }
            var chosen = remaining.remove(at: bestIndex)
            chosen.selectionReason = reason
            selected.append(chosen)
            coveredBins.insert(timeBin(chosen.assetID))
            coveredPeople.insert(peopleBucket(chosen.assetID))
            coveredScenes.insert(scene(chosen.assetID))
            for c in remaining {
                if let d = distance(chosen.assetID, c.assetID) {
                    maxSim[c.assetID] = max(maxSim[c.assetID] ?? 0, max(0, 1 - d / config.similarityHorizon))
                }
            }
        }

        let greedy = max(1, Int((Double(target) * (1 - config.explorationFraction)).rounded()))
        while selected.count < min(greedy, target) { take(scoreWeight: 1, reason: "rank") }
        while selected.count < target { take(scoreWeight: 0.3, reason: "exploration") }
        return selected
    }

    /// 0...1 position over the capture span. Undated photos get no position (they share one bin), except when
    /// nothing is dated: then source order is the only sequence signal and is used for all photos.
    static func timePositions(_ photos: [PhotoRecord]) -> [AssetID: Double] {
        let dates = photos.compactMap(\.metadata.capturedAt)
        var out: [AssetID: Double] = [:]
        if let lo = dates.min(), let hi = dates.max() {
            let span = max(1, hi.timeIntervalSince(lo))
            for p in photos { if let t = p.metadata.capturedAt { out[p.assetID] = t.timeIntervalSince(lo) / span } }
            return out
        }
        let ordered = photos.sorted { $0.sourceRelativePaths[0] < $1.sourceRelativePaths[0] }
        for (i, p) in ordered.enumerated() { out[p.assetID] = Double(i) / Double(max(1, ordered.count)) }
        return out
    }
}
