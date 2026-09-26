import Core
import Foundation

public enum RunReport {
    /// Rebuilds report.html from stored artifacts only (including Studio edits and the interaction log).
    /// Never touches the source folder or the network.
    public static func rebuild(runDirectory: URL) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let ingest = try store.read(IngestResult.self, from: "input-index.json")
        let features = try store.read([PhotoFeatures].self, from: "cache/features.json")
        var thumbs: [AssetID: String] = [:]
        for p in ingest.photos {
            let rel = "cache/thumbnails/analysis/\(p.assetID.rawValue).jpg"
            if FileManager.default.fileExists(atPath: store.url(rel).path) { thumbs[p.assetID] = rel }
        }
        let reduction = try? store.read(ReductionResult.self, from: "cache/reduction.json")
        let concepts = try? store.read(ConceptsReport.self, from: "plans/director.json")
        var edits: [ConceptType: EditedConcept] = [:]
        for c in ConceptType.allCases {
            guard let plan = try? store.read(CarouselPlan.self, from: "edits/\(c.rawValue)/plan.json") else { continue }
            let dir = store.url("edits/\(c.rawValue)/slides")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()) ?? []
            edits[c] = EditedConcept(plan: plan, slides: names.map { "edits/\(c.rawValue)/slides/\($0)" })
        }
        let events = InteractionLog(url: store.url("interaction-events.jsonl")).read()
        let html = ReportBuilder.html(ReportInput(
            manifest: manifest, photos: ingest.photos, skipped: ingest.skipped,
            features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }), thumbnails: thumbs,
            reduction: reduction, concepts: concepts, edits: edits, events: events))
        try store.writeText(html, to: "report.html")
    }
}
