import Core
import Foundation
import Vision

/// Lazily loads cached Vision feature prints and answers pairwise distances.
public final class FeaturePrintIndex: @unchecked Sendable {
    private let cacheRoot: URL
    private let files: [AssetID: String]
    private var prints: [AssetID: FeaturePrintObservation] = [:]
    private var missing: Set<AssetID> = []
    private let lock = NSLock()

    public init(cacheRoot: URL, features: [AssetID: PhotoFeatures]) {
        self.cacheRoot = cacheRoot
        self.files = features.compactMapValues(\.featurePrintFile)
    }

    public func distance(_ a: AssetID, _ b: AssetID) -> Double? {
        guard let pa = print(a), let pb = print(b) else { return nil }
        return try? pa.distance(to: pb)
    }

    /// Distances for every pair within `window` positions of each other in `order`.
    public func neighbourDistances(order: [AssetID], window: Int) -> [PairDistance] {
        var out: [PairDistance] = []
        for i in order.indices {
            for j in (i + 1)..<min(order.count, i + 1 + window) {
                if let d = distance(order[i], order[j]) { out.append(PairDistance(a: order[i], b: order[j], distance: d)) }
            }
        }
        return out
    }

    private func print(_ id: AssetID) -> FeaturePrintObservation? {
        lock.lock(); defer { lock.unlock() }
        if let p = prints[id] { return p }
        if missing.contains(id) { return nil }
        guard let rel = files[id], let data = try? Data(contentsOf: cacheRoot.appending(path: rel)),
              let p = try? JSONDecoder().decode(FeaturePrintObservation.self, from: data) else {
            missing.insert(id); return nil
        }
        prints[id] = p
        return p
    }
}
