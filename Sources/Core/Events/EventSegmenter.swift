import Foundation

public struct EventSegment: Codable, Sendable, Equatable {
    public let index: Int
    public let start: Date?
    public let end: Date?
    public let assetIDs: [AssetID]
    public let photoCount: Int

    public init(index: Int, start: Date?, end: Date?, assetIDs: [AssetID]) {
        self.index = index; self.start = start; self.end = end
        self.assetIDs = assetIDs; self.photoCount = assetIDs.count
    }
}

public enum EventSegmenter {
    private static let hour: TimeInterval = 3_600

    public static func segment(_ photos: [PhotoRecord]) -> [EventSegment] {
        let dated = photos.filter { $0.metadata.capturedAt != nil }.sorted {
            let a = $0.metadata.capturedAt!, b = $1.metadata.capturedAt!
            return a == b ? $0.assetID < $1.assetID : a < b
        }
        guard !dated.isEmpty else {
            return photos.isEmpty ? [] : [EventSegment(index: 1, start: nil, end: nil, assetIDs: photos.map(\.assetID).sorted())]
        }
        var groups: [[PhotoRecord]] = [[dated[0]]]
        for photo in dated.dropFirst() {
            let previous = groups[groups.count - 1].last!
            let gap = photo.metadata.capturedAt!.timeIntervalSince(previous.metadata.capturedAt!)
            let far = distance(previous.metadata.location, photo.metadata.location) > 100
            if gap >= 36 * hour || (gap >= 8 * hour && far) { groups.append([photo]) }
            else { groups[groups.count - 1].append(photo) }
        }
        // Small groups are absorbed by the nearest neighboring event; distance is measured between event edges.
        var i = 0
        while groups.count > 1 && i < groups.count {
            if groups[i].count >= 3 { i += 1; continue }
            let leftGap = i > 0 ? groups[i][0].metadata.capturedAt!.timeIntervalSince(groups[i - 1].last!.metadata.capturedAt!) : .infinity
            let rightGap = i + 1 < groups.count ? groups[i + 1][0].metadata.capturedAt!.timeIntervalSince(groups[i].last!.metadata.capturedAt!) : .infinity
            let target = leftGap <= rightGap ? i - 1 : i + 1
            if target < i { groups[target] += groups[i]; groups.remove(at: i); i = max(0, i - 1) }
            else { groups[i] += groups[target]; groups.remove(at: target) }
        }
        if !groups.isEmpty {
            let undated = photos.filter { $0.metadata.capturedAt == nil }
            if !undated.isEmpty {
                let largest = groups.indices.max { groups[$0].count < groups[$1].count }!
                groups[largest] += undated
            }
        }
        return groups.enumerated().map { index, group in
            let times = group.compactMap(\.metadata.capturedAt)
            return EventSegment(index: index + 1, start: times.min(), end: times.max(), assetIDs: group.map(\.assetID).sorted())
        }
    }

    /// Content-aware refinement of timestamp events. Vision labels are a local scene signature;
    /// only repeated, high-confidence signatures can create a boundary, so one unusual photo
    /// (a meal or a sign, for example) cannot split an otherwise coherent outing.
    public static func segment(_ photos: [PhotoRecord], features: [AssetID: PhotoFeatures]) -> [EventSegment] {
        let timed = segment(photos)
        var refined: [[PhotoRecord]] = []
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        for event in timed {
            let ordered = event.assetIDs.compactMap { byID[$0] }.sorted {
                let a = $0.metadata.capturedAt ?? .distantPast, b = $1.metadata.capturedAt ?? .distantPast
                return a == b ? $0.assetID < $1.assetID : a < b
            }
            let labels = ordered.map { p in signature(features[p.assetID]) }
            // A repeated celebration signature (attire, table setting, festive decoration,
            // wedding terms) can separate an occasion even when timestamps and GPS cannot.
            let wedding = labels.map { $0.contains(where: isWeddingLabel) }
            let gathering = labels.map(isDistinctGatheringSignature)
            let split = wedding.filter({ $0 }).count >= 3 && wedding.filter({ !$0 }).count >= 3
                ? wedding : gathering.filter({ $0 }).count >= 5 && gathering.filter({ !$0 }).count >= 5 ? gathering : nil
            if let split {
                let gatheringPhotos = ordered.enumerated().filter { split[$0.offset] }.map(\.element)
                let otherPhotos = ordered.enumerated().filter { !split[$0.offset] }.map(\.element)
                refined.append(contentsOf: [otherPhotos, gatheringPhotos].filter { !$0.isEmpty })
            } else {
                refined.append(ordered)
            }
        }
        return refined.enumerated().map { index, group in
            let dates = group.compactMap(\.metadata.capturedAt)
            return EventSegment(index: index + 1, start: dates.min(), end: dates.max(), assetIDs: group.map(\.assetID).sorted())
        }
    }

    private static func signature(_ features: PhotoFeatures?) -> [String] {
        Array((features?.labels.prefix(5).map { $0.identifier.lowercased() } ?? []))
    }

    private static func isWeddingLabel(_ label: String) -> Bool {
        ["wedding", "bride", "groom", "bridal", "wedding dress", "wedding ceremony", "wedding reception"]
            .contains(where: label.contains)
    }

    private static func isDistinctGatheringSignature(_ labels: [String]) -> Bool {
        if labels.contains(where: isWeddingLabel) { return true }
        let markers = ["sari", "balloon", "ceremony", "chandelier", "bridal", "bride", "groom", "wedding dress"]
        if labels.contains(where: { label in markers.contains(where: label.contains) }) { return true }
        let setting = ["tableware", "table", "utensil", "furniture", "textile", "curtain", "interior_room"]
        return labels.filter { label in setting.contains(where: label.contains) }.count >= 2 && labels.contains("people")
    }

    private static func distance(_ a: GeoPoint?, _ b: GeoPoint?) -> Double {
        guard let a, let b else { return 0 }
        let radians = Double.pi / 180
        let lat1 = a.latitude * radians, lat2 = b.latitude * radians
        let dLat = (b.latitude - a.latitude) * radians, dLon = (b.longitude - a.longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 6_371 * 2 * asin(min(1, sqrt(h)))
    }
}
