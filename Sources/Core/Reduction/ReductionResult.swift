import Foundation

public struct Funnel: Codable, Sendable, Equatable {
    public var ingested = 0, junkRejected = 0, representatives = 0, shortlisted = 0
    public var triaged = 0, planningPool = 0, selected = 0
    public init() {}
}

public struct ReductionResult: Codable, Sendable {
    /// Hard cap on low-resolution triage images in a model request, including alternate burst frames.
    public static let maximumTriageCandidates = 120
    public var config: ReductionConfig
    public var clusters: [ShotCluster]
    public var junk: [JunkDisposition]
    /// All ranked representatives (post-triage scores once triage ran).
    public var ranked: [RankedCandidate]
    public var shortlist: [RankedCandidate]
    public var planningPool: [RankedCandidate]
    public var funnel: Funnel

    public init(config: ReductionConfig, clusters: [ShotCluster], junk: [JunkDisposition], ranked: [RankedCandidate],
                shortlist: [RankedCandidate], planningPool: [RankedCandidate] = [], funnel: Funnel) {
        self.config = config; self.clusters = clusters; self.junk = junk; self.ranked = ranked
        self.shortlist = shortlist; self.planningPool = planningPool; self.funnel = funnel
    }

    /// Runs clustering → junk → ranking → shortlist selection.
    public static func reduce(photos: [PhotoRecord], features: [AssetID: PhotoFeatures],
                              distance: (AssetID, AssetID) -> Double?, config: ReductionConfig = ReductionConfig()) -> ReductionResult {
        let rawClusters = ShotClusterer.cluster(photos: photos, features: features, distance: distance, config: config)
        let junk = photos.map { JunkFilter.classify(photo: $0, features: features[$0.assetID]) }
        let junkByID = Dictionary(uniqueKeysWithValues: junk.map { ($0.assetID, $0) })
        // A rejected representative hands over to the best non-rejected member of its cluster.
        let clusters = rawClusters.map { c in
            var c = c
            let usable = c.memberAssetIDs.filter { junkByID[$0]?.verdict != .reject }
            if !usable.isEmpty && !usable.contains(c.representativeAssetID) {
                c.representativeAssetID = usable.max { config.technicalScore(features[$0]) < config.technicalScore(features[$1]) }!
            }
            return c
        }
        // Ranking sees only usable members, so cluster size reflects frames that could actually be posted.
        let usableClusters: [ShotCluster] = clusters.compactMap { c in
            var c = c
            c.memberAssetIDs = c.memberAssetIDs.filter { junkByID[$0]?.verdict != .reject }
            return c.memberAssetIDs.isEmpty ? nil : c
        }
        let ranked = CandidateRanker.rank(photos: photos, features: features, clusters: usableClusters, junk: junkByID, config: config)
        let photoByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        let target = ReductionTargets.forUsable(ranked.count).triage
        let shortlist = DiversitySelector.select(ranked: ranked, target: target, photos: photoByID, features: features,
                                                 distance: distance, config: config)
        var funnel = Funnel()
        funnel.ingested = photos.count
        funnel.junkRejected = junk.filter { $0.verdict == .reject }.count
        funnel.representatives = ranked.count
        funnel.shortlisted = shortlist.count
        return ReductionResult(config: config, clusters: clusters, junk: junk, ranked: ranked, shortlist: shortlist, funnel: funnel)
    }

    /// Adds at most one safe alternate per shortlisted burst, preserving shortlist representatives first.
    /// The fixed cap bounds thumbnail generation and model image count. Ties resolve by AssetID.
    public func triageCandidates(photos: [PhotoRecord], features: [AssetID: PhotoFeatures],
                                 limit: Int = maximumTriageCandidates) -> [RankedCandidate] {
        let limit = max(0, limit)
        let base = Array(shortlist.prefix(limit))
        guard base.count < limit else { return base }
        let junkByID = Dictionary(uniqueKeysWithValues: junk.map { ($0.assetID, $0) })
        let clustersByID = Dictionary(uniqueKeysWithValues: clusters.map { ($0.clusterID, $0) })
        var alternatives: [RankedCandidate] = []
        for candidate in base {
            guard alternatives.count < limit - base.count,
                  var cluster = clustersByID[candidate.clusterID] else { break }
            let safeMembers = cluster.memberAssetIDs.filter { junkByID[$0]?.verdict != .reject }
            let alternativesForCluster = safeMembers.filter { $0 != candidate.assetID }
            guard !alternativesForCluster.isEmpty else { continue }
            cluster.memberAssetIDs = safeMembers
            let bestID = alternativesForCluster.max { lhs, rhs in
                let left = config.technicalScore(features[lhs]), right = config.technicalScore(features[rhs])
                return left == right ? lhs > rhs : left < right
            }!
            cluster.representativeAssetID = bestID
            if let alternate = CandidateRanker.rank(photos: photos, features: features, clusters: [cluster],
                                                     junk: junkByID, config: config).first {
                alternatives.append(alternate)
            }
        }
        return base + alternatives
    }
}
