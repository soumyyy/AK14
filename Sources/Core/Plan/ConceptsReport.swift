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
    /// Run-relative PNG paths of the rendered Plain Dump, in order.
    public var plainSlides: [String]

    public init(status: String, stylePackID: String, stylePackVersion: String, triage: [String: TriageScore],
                pool: [AssetID], spine: SelectionSpine?, recommendedSlideCount: Int?, plans: [CarouselPlan],
                unavailable: [String: String], deviations: [String: Deviation], diversity: ConceptDistance?,
                warnings: [String], plainSlides: [String]) {
        self.status = status; self.stylePackID = stylePackID; self.stylePackVersion = stylePackVersion
        self.triage = triage; self.pool = pool; self.spine = spine; self.recommendedSlideCount = recommendedSlideCount
        self.plans = plans; self.unavailable = unavailable; self.deviations = deviations; self.diversity = diversity
        self.warnings = warnings; self.plainSlides = plainSlides
    }
}
