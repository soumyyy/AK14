import Foundation

public enum SlotAssignment {
    public static let cropFloor = 0.65
    public struct Placed: Codable, Sendable, Equatable {
        public var slotIndex: Int
        public var assetID: AssetID
        public var crop: UnitRect
    }
    public struct Result: Sendable, Equatable {
        public var placed: [Placed]
        public var cost: Double
    }
    static let infeasible = 1e6

    public static func readingOrder(_ page: DesignedSet) -> [Int] {
        page.expandedSlots.enumerated().sorted { l, r in
            let a = (l.element.frame.y + l.element.frame.height / 2, l.element.frame.x + l.element.frame.width / 2)
            let b = (r.element.frame.y + r.element.frame.height / 2, r.element.frame.x + r.element.frame.width / 2)
            if abs(a.0 - b.0) > 0.05 { return a.0 < b.0 }
            return a.1 < b.1
        }.map(\.offset)
    }

    /// The photo window's aspect: a frame's transparent window when the slot sits in one, else the slot's.
    static func boxAspect(_ slot: DesignedSet.Slot, page: DesignedSet) -> Double {
        if let frame = page.frames?.first(where: { $0.slotFrame.map { abs($0.x - slot.frame.x) + abs($0.y - slot.frame.y) < 0.01 } ?? false }),
           let window = frame.photoWindowAspect { return window }
        return slot.aspect > 0 ? slot.aspect : slot.frame.width / max(slot.frame.height, 0.01)
    }

    static func pair(_ id: AssetID, _ slot: DesignedSet.Slot, page: DesignedSet, isHero: Bool, largestArea: Double,
                     records: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures]) -> (cost: Double, crop: UnitRect) {
        guard let record = records[id] else { return (infeasible, UnitRect(x: 0, y: 0, width: 1, height: 1)) }
        let imageAspect = Double(record.pixelWidth) / Double(max(record.pixelHeight, 1))
        let f = features[id]
        let crop = CropPlanner.cover(imageAspect: imageAspect, boxAspect: boxAspect(slot, page: page), features: f)
        let kept = crop.width * crop.height
        guard kept >= cropFloor, CropPlanner.facesFit(f, crop: crop),
              !TemplateVocabulary.subjectCrossesSeam(features: f, crop: crop, slot: slot.frame) else { return (infeasible, crop) }
        var cost = 1 - kept
        // Relevant faces: the largest, plus every face at least 40% of its height.
        let heights = (f?.faces ?? []).map(\.box.height)
        if let biggest = heights.max(), biggest > 0 {
            let relevant = heights.filter { $0 >= 0.4 * biggest }
            let rendered = relevant.map { $0 / max(crop.height, 1e-6) * slot.frame.height }.min() ?? 1
            if rendered < 0.04 { cost += 2 * (0.04 - rendered) / 0.04 }
        }
        if isHero { cost += 0.3 * (1 - slot.frame.width * slot.frame.height / max(largestArea, 1e-6)) }
        return (cost, crop)
    }

    public static func assign(_ photos: [AssetID], to page: DesignedSet, hero: AssetID?, keepOrder: Bool,
                              records: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures]) -> Result? {
        let slots = page.expandedSlots
        guard !photos.isEmpty, photos.count == slots.count, Set(photos).count == photos.count else { return nil }
        let largest = slots.map { $0.frame.width * $0.frame.height }.max() ?? 1
        let table = photos.map { id in slots.map { pair(id, $0, page: page, isHero: id == hero, largestArea: largest, records: records, features: features) } }
        let columns: [Int]
        if keepOrder {
            let order = readingOrder(page)
            columns = photos.indices.map { order[$0] }
        } else {
            columns = hungarian(table.map { $0.map(\.cost) })
        }
        var placed: [Placed] = [], total = 0.0
        for (row, column) in columns.enumerated() {
            let (cost, crop) = table[row][column]
            guard cost < infeasible else { return nil }
            placed.append(Placed(slotIndex: column, assetID: photos[row], crop: crop)); total += cost
        }
        return Result(placed: placed.sorted { $0.slotIndex < $1.slotIndex }, cost: total)
    }

    /// Minimum-cost perfect matching on a square matrix (O(n³)). Returns the column for each row.
    static func hungarian(_ cost: [[Double]]) -> [Int] {
        let n = cost.count
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i; var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1), used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]; var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n { if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta } }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var result = [Int](repeating: 0, count: n)
        for j in 1...n where p[j] != 0 { result[p[j] - 1] = j - 1 }
        return result
    }
}
