import Foundation

/// Everything the report and `rerender` need from the Director stage, persisted as plans/director.json.
public struct ConceptsReport: Codable, Sendable {
    public var status: String
    public var stylePackID: String
    public var stylePackVersion: String
    public var triage: [String: TriageScore]
    public var pool: [AssetID]
    public var spine: SelectionSpine?
    public var recommendedSlideCount: Int?
    public var plans: [CarouselPlan]
    public var unavailable: [String: String]
    public var deviations: [String: Deviation]
    public var diversity: ConceptDistance?
    public var warnings: [String]
    /// Concept type → run-relative PNG paths, in slide order.
    public var renderedSlides: [String: [String]]
    public var plainSlides: [String] { renderedSlides[ConceptType.plainDump.rawValue] ?? [] }

    public init(status: String, stylePackID: String, stylePackVersion: String, triage: [String: TriageScore],
                pool: [AssetID], spine: SelectionSpine?, recommendedSlideCount: Int?, plans: [CarouselPlan],
                unavailable: [String: String], deviations: [String: Deviation], diversity: ConceptDistance?,
                warnings: [String], renderedSlides: [String: [String]]) {
        self.status = status; self.stylePackID = stylePackID; self.stylePackVersion = stylePackVersion
        self.triage = triage; self.pool = pool; self.spine = spine; self.recommendedSlideCount = recommendedSlideCount
        self.plans = plans; self.unavailable = unavailable; self.deviations = deviations; self.diversity = diversity
        self.warnings = warnings; self.renderedSlides = renderedSlides
    }

    enum CodingKeys: String, CodingKey {
        case status, stylePackID, stylePackVersion, triage, pool, spine, recommendedSlideCount, plans, unavailable
        case deviations, diversity, warnings, renderedSlides, plainSlides
    }

    /// Runs written before M4 stored only `plainSlides`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        stylePackID = try c.decode(String.self, forKey: .stylePackID)
        stylePackVersion = try c.decode(String.self, forKey: .stylePackVersion)
        triage = try c.decodeIfPresent([String: TriageScore].self, forKey: .triage) ?? [:]
        pool = try c.decodeIfPresent([AssetID].self, forKey: .pool) ?? []
        spine = try c.decodeIfPresent(SelectionSpine.self, forKey: .spine)
        recommendedSlideCount = try c.decodeIfPresent(Int.self, forKey: .recommendedSlideCount)
        plans = try c.decodeIfPresent([CarouselPlan].self, forKey: .plans) ?? []
        unavailable = try c.decodeIfPresent([String: String].self, forKey: .unavailable) ?? [:]
        deviations = try c.decodeIfPresent([String: Deviation].self, forKey: .deviations) ?? [:]
        diversity = try c.decodeIfPresent(ConceptDistance.self, forKey: .diversity)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        if let rendered = try c.decodeIfPresent([String: [String]].self, forKey: .renderedSlides) {
            renderedSlides = rendered
        } else {
            let plain = try c.decodeIfPresent([String].self, forKey: .plainSlides) ?? []
            renderedSlides = plain.isEmpty ? [:] : [ConceptType.plainDump.rawValue: plain]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(stylePackID, forKey: .stylePackID)
        try c.encode(stylePackVersion, forKey: .stylePackVersion); try c.encode(triage, forKey: .triage)
        try c.encode(pool, forKey: .pool); try c.encodeIfPresent(spine, forKey: .spine)
        try c.encodeIfPresent(recommendedSlideCount, forKey: .recommendedSlideCount); try c.encode(plans, forKey: .plans)
        try c.encode(unavailable, forKey: .unavailable); try c.encode(deviations, forKey: .deviations)
        try c.encodeIfPresent(diversity, forKey: .diversity); try c.encode(warnings, forKey: .warnings)
        try c.encode(renderedSlides, forKey: .renderedSlides)
    }
}
