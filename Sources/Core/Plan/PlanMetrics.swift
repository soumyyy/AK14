import Foundation

public struct Deviation: Codable, Sendable, Equatable {
    public var added: [AssetID]
    public var removed: [AssetID]
    public var coverChanged: Bool
    /// Kendall tau-style agreement (−1...1) over photos shared with the spine; 1 = same order.
    public var orderSimilarity: Double
    public var slideCount: Int
    public var photoCount: Int
}

public struct ConceptDistance: Codable, Sendable, Equatable {
    /// The pair compared (absent in runs before the composer engine, which compared designed and wildcard).
    public var a: String?
    public var b: String?
    /// Fraction of style axes that differ.
    public var styleDistance: Double?
    public var jaccard: Double
    public var sameCover: Bool
    public var orderSimilarity: Double
    public var structuralDiffs: [String]
    public var passes: Bool
}

public enum PlanMetrics {
    public static func deviation(plan: CarouselPlan, spine: SelectionSpine) -> Deviation {
        let ids = plan.photoAssetIDs, s = spine.orderedAssetIDs
        return Deviation(added: ids.filter { !s.contains($0) }, removed: s.filter { !ids.contains($0) },
                         coverChanged: plan.coverAssetID != spine.coverAssetID,
                         orderSimilarity: orderAgreement(s, ids), slideCount: plan.slides.count, photoCount: ids.count)
    }

    public static func diversity(_ a: CarouselPlan, _ b: CarouselPlan) -> ConceptDistance {
        let sa = Set(a.photoAssetIDs), sb = Set(b.photoAssetIDs)
        let jaccard = sa.union(sb).isEmpty ? 1 : Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        var diffs: [String] = []
        if primitiveMix(a) != primitiveMix(b) { diffs.append("primitiveMix") }
        if abs(multiRatio(a) - multiRatio(b)) > 0.2 { diffs.append("singleMultiRatio") }
        if a.slides.map(\.density) != b.slides.map(\.density) { diffs.append("densityRhythm") }
        if decorationProfile(a) != decorationProfile(b) { diffs.append("decorationProfile") }
        let sameCover = a.coverAssetID == b.coverAssetID
        let order = orderAgreement(a.photoAssetIDs, b.photoAssetIDs)
        return ConceptDistance(a: a.id, b: b.id, styleDistance: a.style.flatMap { sa in b.style.map { sa.distance(to: $0) } },
                               jaccard: jaccard, sameCover: sameCover, orderSimilarity: order, structuralDiffs: diffs,
                               // Structure is the primary signal (spec §6.5 prefers changing structure over selection):
                               // with 3+ structural differences, photo overlap from a shared strong spine is fine.
                               passes: !sameCover && diffs.count >= 2 && (jaccard <= 0.8 || order < 0.5 || diffs.count >= 3))
    }

    static func primitiveMix(_ p: CarouselPlan) -> [String: Int] {
        Dictionary(grouping: p.slides, by: { $0.primitive.rawValue }).mapValues(\.count)
    }
    static func multiRatio(_ p: CarouselPlan) -> Double {
        p.slides.isEmpty ? 0 : Double(p.slides.filter { $0.photos.count > 1 }.count) / Double(p.slides.count)
    }
    static func decorationProfile(_ p: CarouselPlan) -> Set<String> {
        Set(p.slides.flatMap { $0.decorations.map(\.decorationID) })
    }

    /// Pairwise order agreement over shared items: (concordant − discordant) / pairs; 1 when < 2 shared.
    static func orderAgreement(_ x: [AssetID], _ y: [AssetID]) -> Double {
        let posY = Dictionary(uniqueKeysWithValues: y.enumerated().map { ($1, $0) })
        let shared = x.filter { posY[$0] != nil }
        guard shared.count >= 2 else { return 1 }
        var concordant = 0, discordant = 0
        for i in 0..<shared.count { for j in (i + 1)..<shared.count {
            if posY[shared[i]]! < posY[shared[j]]! { concordant += 1 } else { discordant += 1 }
        } }
        return Double(concordant - discordant) / Double(concordant + discordant)
    }
}
