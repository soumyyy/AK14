import Foundation

public struct TriageScore: Codable, Sendable, Equatable {
    public var emotionalValue: Int
    /// useful | neutral | accident
    public var imperfection: String
    public var safety: [String]
    public var tags: [String]
    public var confidence: String
    public init(emotionalValue: Int, imperfection: String, safety: [String], tags: [String], confidence: String) {
        self.emotionalValue = emotionalValue; self.imperfection = imperfection; self.safety = safety
        self.tags = tags; self.confidence = confidence
    }
}

public struct RankComponents: Codable, Sendable, Equatable {
    public var usability: Double?, people: Double?, saliency: Double?, aesthetic: Double?
    public var semantic: Double?, distinctiveness: Double?, userSignal: Double?
    public var penalty: Double
    public var base: Double
}

public struct RankedCandidate: Codable, Sendable, Equatable {
    public let assetID: AssetID
    public let clusterID: String
    public let clusterSize: Int
    public var components: RankComponents
    public var score: Double
    public var triage: TriageScore?
    public var adjustedScore: Double?
    /// "rank" or "exploration" once selected.
    public var selectionReason: String?

    public var effectiveScore: Double { adjustedScore ?? score }
}

public enum CandidateRanker {
    static let personalityLabels = ["food", "dessert", "drink", "beverage", "coffee", "cake", "sign", "text",
                                    "animal", "dog", "cat", "vehicle", "car", "building", "fireworks", "concert",
                                    "night", "sunset", "waterfall", "beach", "flower"]

    public static func rank(photos: [PhotoRecord], features: [AssetID: PhotoFeatures], clusters: [ShotCluster],
                            junk: [AssetID: JunkDisposition], config: ReductionConfig) -> [RankedCandidate] {
        let topLabels = features.values.compactMap { $0.labels.first?.identifier }
        let labelFreq = Dictionary(grouping: topLabels, by: { $0 }).mapValues { Double($0.count) / Double(max(1, topLabels.count)) }

        var out: [RankedCandidate] = []
        for c in clusters {
            let id = c.representativeAssetID
            guard junk[id]?.verdict != .reject else { continue }
            let f = features[id]
            var comp = RankComponents(penalty: junk[id].map(JunkFilter.penalty) ?? 0, base: 0)
            if let f {
                if let s = config.sharp01(f), let d = f.darkFraction { comp.usability = 0.6 * s + 0.4 * (1 - d) }
                if f.faces.isEmpty { comp.people = 0 } else {
                    let q = f.faces.compactMap(\.captureQuality)
                    let mean = q.isEmpty ? 0.5 : q.reduce(0, +) / Double(q.count)
                    comp.people = min(1, 0.5 + 0.5 * mean + (f.faces.count >= 3 ? 0.1 : 0))
                }
                comp.saliency = min(1, (f.salientRegions.map { $0.width * $0.height }.max() ?? 0) / 0.4)
                comp.aesthetic = f.aestheticScore.map { ($0 + 1) / 2 }
                var semantic = 0.4
                if f.labels.prefix(3).contains(where: { l in personalityLabels.contains { l.identifier.contains($0) } }) { semantic += 0.3 }
                if let top = f.labels.first?.identifier, (labelFreq[top] ?? 0) < 0.05 { semantic += 0.3 }
                comp.semantic = semantic
            }
            comp.distinctiveness = 1 - min(1, Double(c.memberAssetIDs.count) / 10)
            comp.userSignal = 0

            let w = config.weights
            let pairs: [(Double?, Double)] = [(comp.usability, w.usability), (comp.people, w.people), (comp.saliency, w.saliency),
                                              (comp.aesthetic, w.aesthetic), (comp.semantic, w.semantic),
                                              (comp.distinctiveness, w.distinctiveness), (comp.userSignal, w.userSignal)]
            let present = pairs.filter { $0.0 != nil }
            let weightSum = present.reduce(0) { $0 + $1.1 }
            let weighted = present.reduce(0) { $0 + $1.0! * $1.1 }
            comp.base = weightSum > 0 ? weighted / weightSum : 0
            out.append(RankedCandidate(assetID: id, clusterID: c.clusterID, clusterSize: c.memberAssetIDs.count,
                                       components: comp, score: max(0, comp.base - comp.penalty)))
        }
        return out.sorted { $0.score == $1.score ? $0.assetID < $1.assetID : $0.score > $1.score }
    }

    /// Bounded triage adjustment (spec §5.4): at most ±`triageMaxAdjustment` of the pre-triage score.
    public static func applyTriage(_ ranked: [RankedCandidate], triage: [AssetID: TriageScore],
                                   config: ReductionConfig) -> [RankedCandidate] {
        ranked.map { r in
            var r = r
            guard let t = triage[r.assetID] else { return r }
            let imperfection = t.imperfection == "useful" ? 0.05 : t.imperfection == "accident" ? -0.2 : 0
            let adj = min(config.triageMaxAdjustment, max(-config.triageMaxAdjustment,
                          0.2 * (Double(t.emotionalValue) - 2.5) / 2.5 + imperfection))
            r.triage = t
            r.adjustedScore = r.score * (1 + adj)
            return r
        }.sorted { $0.effectiveScore == $1.effectiveScore ? $0.assetID < $1.assetID : $0.effectiveScore > $1.effectiveScore }
    }
}
