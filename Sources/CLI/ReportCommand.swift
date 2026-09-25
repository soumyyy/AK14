import Core
import Foundation

enum ReportCommand {
    /// Rebuilds report.html from stored artifacts only. Never touches the source folder or the network.
    static func rebuild(runDirectory: URL) throws {
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
        let html = ReportBuilder.html(ReportInput(
            manifest: manifest, photos: ingest.photos, skipped: ingest.skipped,
            features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }), thumbnails: thumbs,
            reduction: reduction, concepts: concepts))
        try store.writeText(html, to: "report.html")
    }
}
