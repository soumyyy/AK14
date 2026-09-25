import Foundation

public struct PairDistance: Codable, Sendable, Equatable {
    public let a: AssetID, b: AssetID, distance: Double
    public init(a: AssetID, b: AssetID, distance: Double) { self.a = a; self.b = b; self.distance = distance }
}

public enum ShotKind: String, Codable, Sendable { case single, nearDuplicate, shotGroup }

public struct ShotCluster: Codable, Sendable, Equatable {
    public let clusterID: String
    public var memberAssetIDs: [AssetID]
    public var representativeAssetID: AssetID
    public var kind: ShotKind
    public var maxDistance: Double
    public var captureSpanSeconds: Double?
}

public enum ShotClusterer {
    /// Capture-time order; undated photos last, in source-path order.
    public static func captureOrder(_ photos: [PhotoRecord]) -> [PhotoRecord] {
        photos.sorted {
            switch ($0.metadata.capturedAt, $1.metadata.capturedAt) {
            case let (a?, b?): return a == b ? $0.assetID < $1.assetID : a < b
            case (nil, nil): return $0.sourceRelativePaths[0] < $1.sourceRelativePaths[0]
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    /// Greedy time-ordered clustering. A photo joins the cluster of its closest earlier neighbour when the pair
    /// forms a duplicate edge or a shot edge, the cluster anchor is still within `shotDistance`, and the
    /// cluster's time span stays under the cap. Undated pairs need duplicate-level similarity.
    public static func cluster(photos: [PhotoRecord], features: [AssetID: PhotoFeatures],
                               distance: (AssetID, AssetID) -> Double?, config: ReductionConfig) -> [ShotCluster] {
        struct Work { var members: [AssetID]; var anchor: AssetID; var first: Date?; var last: Date?; var allDup: Bool; var maxD: Double }
        let order = captureOrder(photos)
        var work: [Work] = []
        var clusterOf: [AssetID: Int] = [:]

        for (i, p) in order.enumerated() {
            var best: (cluster: Int, d: Double, dup: Bool)?
            for j in max(0, i - config.neighbourWindow)..<i {
                let q = order[j]
                guard let d = distance(q.assetID, p.assetID), let c = clusterOf[q.assetID] else { continue }
                let dt = zip2(q.metadata.capturedAt, p.metadata.capturedAt).map { abs($1.timeIntervalSince($0)) }
                let dup = d <= config.dupDistance && (dt.map { $0 <= config.dupSeconds } ?? true)
                let shot = d <= config.shotDistance && (dt.map { $0 <= config.shotSeconds } ?? (d <= config.dupDistance))
                guard dup || shot else { continue }
                if let t = p.metadata.capturedAt, let first = work[c].first,
                   t.timeIntervalSince(first) > config.maxClusterSpanSeconds { continue }
                if work[c].anchor != q.assetID,
                   (distance(work[c].anchor, p.assetID) ?? .infinity) > config.shotDistance { continue }
                if best == nil || d < best!.d { best = (c, d, dup) }
            }
            if let best {
                work[best.cluster].members.append(p.assetID)
                work[best.cluster].allDup = work[best.cluster].allDup && best.dup
                work[best.cluster].maxD = max(work[best.cluster].maxD, best.d)
                if let t = p.metadata.capturedAt { work[best.cluster].last = t; if work[best.cluster].first == nil { work[best.cluster].first = t } }
                clusterOf[p.assetID] = best.cluster
            } else {
                clusterOf[p.assetID] = work.count
                work.append(Work(members: [p.assetID], anchor: p.assetID, first: p.metadata.capturedAt,
                                 last: p.metadata.capturedAt, allDup: true, maxD: 0))
            }
        }

        return work.map { w in
            let rep = w.members.max { a, b in
                let sa = config.technicalScore(features[a]), sb = config.technicalScore(features[b])
                return sa == sb ? a > b : sa < sb
            }!
            let span = zip2(w.first, w.last).map { $1.timeIntervalSince($0) }
            return ShotCluster(clusterID: "c_" + w.members[0].rawValue.dropFirst(2), memberAssetIDs: w.members,
                               representativeAssetID: rep,
                               kind: w.members.count == 1 ? .single : w.allDup ? .nearDuplicate : .shotGroup,
                               maxDistance: w.maxD, captureSpanSeconds: span)
        }
    }
}

func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
