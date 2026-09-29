import Foundation

public struct ValidationIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    /// nil = spine / response level; otherwise the index of the direction the issue belongs to.
    public var direction: Int?
    public var path: String
    public var message: String
    public var description: String { "\(path): \(message)" }
    public init(direction: Int? = nil, path: String, message: String) {
        self.direction = direction; self.path = path; self.message = message
    }
}

/// Semantic validation of a planner response (spec §6.4). Schema shape is enforced by strict JSON schema + decoding.
public enum PlanValidator {
    public static func validate(_ r: PlannerResponse, pool: [AssetID],
                                flagged: Set<AssetID>, requestedSlides: Int? = nil,
                                exactSet: Bool = false, keepOrder: Bool = false) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let poolSet = Set(pool)
        let minSlides = min(5, pool.count)

        // Spine
        let spine = r.spine.orderedAssetIDs
        if exactSet && (Set(spine) != poolSet || spine.count != pool.count) { issues.append(.init(path: "spine.orderedAssetIDs", message: "must contain every exact photo exactly once")) }
        if keepOrder && spine != pool { issues.append(.init(path: "spine.orderedAssetIDs", message: "must preserve the exact input order")) }
        if Set(spine).count != spine.count { issues.append(.init(path: "spine.orderedAssetIDs", message: "duplicate asset IDs")) }
        for id in spine where !poolSet.contains(id) {
            issues.append(.init(path: "spine.orderedAssetIDs", message: "\(id) is not a candidate"))
        }
        if !(minSlides...20).contains(spine.count) {
            issues.append(.init(path: "spine.orderedAssetIDs", message: "has \(spine.count) photos; need \(minSlides)...20"))
        }
        if !exactSet, let n = requestedSlides, spine.count > n {
            issues.append(.init(path: "spine.orderedAssetIDs", message: "has \(spine.count) photos; the user asked for at most \(n)"))
        }
        if let cover = spine.first, flagged.contains(cover), spine.contains(where: { !flagged.contains($0) }) {
            issues.append(.init(path: "spine.cover", message: "cover \(cover) has a social-safety flag; put an unflagged photo first"))
        }
        if r.spine.sequenceIntent.count != spine.count {
            issues.append(.init(path: "spine.sequenceIntent", message: "has \(r.spine.sequenceIntent.count) entries; need \(spine.count)"))
        }

        // Directions: each is checked on its own so one bad direction never costs the others.
        if r.directions.isEmpty { issues.append(.init(path: "directions", message: "need 2-5 directions")) }
        for (i, d) in r.directions.enumerated() {
            func add(_ path: String, _ msg: String) { issues.append(.init(direction: i, path: "directions[\(i)].\(path)", message: msg)) }
            let ids = d.orderedAssetIDs, set = Set(ids)
            if exactSet && (set != poolSet || ids.count != pool.count) { add("orderedAssetIDs", "must contain every exact photo exactly once") }
            if keepOrder && ids != pool { add("orderedAssetIDs", "must preserve the exact input order") }
            if set.count != ids.count { add("orderedAssetIDs", "duplicate asset IDs") }
            for id in ids where !poolSet.contains(id) { add("orderedAssetIDs", "\(id) is not a candidate") }
            let maxDirectionPhotos = d.moments.isEmpty ? 20 : 30
            if !(minSlides...maxDirectionPhotos).contains(ids.count) { add("orderedAssetIDs", "has \(ids.count) photos; need \(minSlides)...\(maxDirectionPhotos)") }
            if d.moments.isEmpty, !exactSet, let n = requestedSlides, d.style.grouping == "single", ids.count > n {
                add("orderedAssetIDs", "has \(ids.count) photos, one per slide; the user asked for at most \(n) slides")
            }
            if !d.moments.isEmpty {
                let flat = d.moments.flatMap(\.photos)
                for (m, moment) in d.moments.enumerated() {
                    if moment.photos.isEmpty { add("moments[\(m)]", "empty moment") }
                    if !moment.mustInclude.allSatisfy(moment.photos.contains) { add("moments[\(m)].mustInclude", "must be photos of this moment") }
                    if !["1", "few", "many"].contains(moment.size) { add("moments[\(m)].size", "unknown size") }
                }
                if !d.coverCandidates.allSatisfy(Set(flat).contains) { add("coverCandidates", "must be photos in this direction's moments") }
                if d.coverCandidates.isEmpty { add("coverCandidates", "must not be empty when moments are present") }
            }
            if !set.contains(d.coverAssetID) { add("coverAssetID", "\(d.coverAssetID) is not in this direction's photos") }
            if flagged.contains(d.coverAssetID), ids.contains(where: { !flagged.contains($0) }) {
                add("coverAssetID", "cover \(d.coverAssetID) has a social-safety flag while unflagged photos are available")
            }
            for g in d.keepTogether where !g.allSatisfy(set.contains) || !(2...4).contains(g.count) {
                add("keepTogether", "each group needs 2-4 of this direction's photos")
            }
            for id in d.emphasisAssetIDs where !set.contains(id) { add("emphasisAssetIDs", "\(id) is not in this direction's photos") }
            if d.style.normalized != d.style { add("style", "unknown style value") }
        }
        return issues
    }
}
