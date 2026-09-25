import Foundation

public struct ValidationIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    /// nil = spine / response level; otherwise the concept the issue belongs to.
    public var concept: ConceptType?
    public var path: String
    public var message: String
    public var description: String { "\(path): \(message)" }
    public init(concept: ConceptType? = nil, path: String, message: String) {
        self.concept = concept; self.path = path; self.message = message
    }
}

/// Semantic validation of a planner response (spec §6.4). Schema shape is enforced by strict JSON schema + decoding.
public enum PlanValidator {
    public static func validate(_ r: PlannerResponse, pool: [AssetID], stylePack: StylePack,
                                flagged: Set<AssetID>) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let poolSet = Set(pool)
        let minSlides = min(5, pool.count)

        // Spine
        let spine = r.spine.orderedAssetIDs
        if Set(spine).count != spine.count { issues.append(.init(path: "spine.orderedAssetIDs", message: "duplicate asset IDs")) }
        for id in spine where !poolSet.contains(id) {
            issues.append(.init(path: "spine.orderedAssetIDs", message: "\(id) is not a candidate"))
        }
        if !(minSlides...20).contains(spine.count) {
            issues.append(.init(path: "spine.orderedAssetIDs", message: "has \(spine.count) photos; need \(minSlides)...20"))
        }
        if r.spine.sequenceIntent.count != spine.count {
            issues.append(.init(path: "spine.sequenceIntent", message: "has \(r.spine.sequenceIntent.count) entries; need \(spine.count)"))
        }

        // Concept set
        let types = r.plans.map(\.conceptType)
        if types.count != 3 || Set(types) != Set(ConceptType.allCases) {
            issues.append(.init(path: "plans", message: "need exactly one plainDump, one designed and one wildcard; got \(types.map(\.rawValue))"))
        }

        for plan in r.plans {
            let c = plan.conceptType
            func add(_ path: String, _ msg: String) { issues.append(.init(concept: c, path: "plans[\(c.rawValue)].\(path)", message: msg)) }
            if !(minSlides...20).contains(plan.slides.count) { add("slides", "has \(plan.slides.count) slides; need \(minSlides)...20") }
            let ids = plan.photoAssetIDs
            if Set(ids).count != ids.count { add("slides", "a photo is used more than once") }
            for id in ids where !poolSet.contains(id) { add("slides", "\(id) is not a candidate") }
            for (i, s) in plan.slides.enumerated() {
                if !s.primitive.photoRange.contains(s.photos.count) {
                    add("slides[\(i)]", "\(s.primitive.rawValue) needs \(s.primitive.photoRange) photos, has \(s.photos.count)")
                }
                for d in s.decorations where !stylePack.decorationIDs.contains(d.decorationID) {
                    add("slides[\(i)].decorations", "unknown decorationID \(d.decorationID)")
                }
            }
            if c == .plainDump {
                if ids != spine { add("slides", "Plain Dump must use exactly the spine photos in spine order") }
                for (i, s) in plan.slides.enumerated() {
                    if ![.fullBleed, .hero].contains(s.primitive) { add("slides[\(i)].primitive", "Plain Dump allows only full_bleed or hero") }
                    if !s.decorations.isEmpty || !s.stamps.isEmpty { add("slides[\(i)]", "Plain Dump must have no decorations or stamps") }
                }
            }
            if let cover = plan.coverAssetID, flagged.contains(cover), ids.contains(where: { !flagged.contains($0) }) {
                add("slides[0]", "cover \(cover) has a social-safety flag while unflagged photos are available")
            }
        }
        return issues
    }
}
