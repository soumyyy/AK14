import Analysis
import Core
import Foundation
import Render
import Session

enum RerenderCommand {
    enum Failure: Error, CustomStringConvertible {
        case noPlans, changed(String), render([String])
        var description: String {
            switch self {
            case .noPlans: "run has no concept plans to render"
            case .changed(let p): "source photo changed since the run: \(p)"
            case .render(let f): "rerender failed; previous slides kept: \(f.prefix(5).joined(separator: "; "))"
            }
        }
    }

    /// Re-resolves and re-renders every concept from saved plans and the source folder. Never calls the model.
    /// Renders into a staging directory and swaps only if every slide succeeded, so a failure keeps the old output.
    /// `recompose` first re-runs the page search on the stored directions (legacy plans without one are kept).
    static func rerender(runDirectory: URL, source: URL, seed: UInt64? = nil, recompose: Bool = false) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let ingest = try store.read(IngestResult.self, from: "input-index.json")
        let features = try store.read([PhotoFeatures].self, from: "cache/features.json")
        var concepts = try store.read(ConceptsReport.self, from: "plans/director.json")
        guard !concepts.plans.isEmpty else { throw Failure.noPlans }
        if recompose, let spine = concepts.spine {
            // Search all stored directions together to retain distinct families and covers.
            // Edited and handed-off plans keep their original artifacts.
            let fm = FileManager.default
            let touched = Set(concepts.plans.map(\.id).filter { id in
                fm.fileExists(atPath: store.url("edits/\(id)").path)
                    || ((try? fm.contentsOfDirectory(atPath: store.url("handoffs").path)) ?? []).contains { $0.hasPrefix("\(id)-") }
            })
            let context = try RunSession(runDirectory: runDirectory).compositionContext()
            let directed = concepts.plans.filter { !$0.isBaseline && $0.direction != nil }
            if !directed.isEmpty {
                let set = ComposerEngine.composeSet(directions: directed.compactMap(\.direction), spine: spine,
                                                    context: context, runID: manifest.runID)
                var fresh: [String: CarouselPlan] = [:]
                if concepts.baseline?.direction != nil { fresh[CarouselPlan.baselineID] = set.plans.first { $0.isBaseline } }
                for (index, original) in directed.enumerated() {
                    if var plan = set.plans.first(where: { $0.id == "c\(index + 1)" }) {
                        plan.id = original.id
                        fresh[original.id] = plan
                    }
                }
                concepts.plans = concepts.plans.map { touched.contains($0.id) ? $0 : fresh[$0.id] ?? $0 }
                concepts.warnings += set.warnings
            }
            for id in touched.sorted() { concepts.warnings.append("\(id): not recomposed (it has edits or a hand-off)") }
            var seenWarnings = Set<String>()
            concepts.warnings = concepts.warnings.filter { seenWarnings.insert($0).inserted }
            let directions = concepts.plans.filter { !$0.isBaseline }
            concepts.diversity = directions.indices.flatMap { i in directions.indices.filter { $0 > i }.map { j in
                PlanMetrics.diversity(directions[i], directions[j]) } }
            concepts.deviations = Dictionary(uniqueKeysWithValues: directions.map { ($0.id, PlanMetrics.deviation(plan: $0, spine: spine)) })
            for p in concepts.plans { try store.write(p, to: "plans/\(p.id).json") }
        }
        let photos = Dictionary(uniqueKeysWithValues: ingest.photos.map { ($0.assetID, $0) })
        let folder = try verifiedSource(source, photos: photos, assetIDs: concepts.plans.flatMap(\.photoAssetIDs))
        let fm = FileManager.default
        let staging = store.url(".rerender")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if fm.fileExists(atPath: store.url("documents").path) {
            try fm.copyItem(at: store.url("documents"), to: staging.appending(path: "documents"))
        }
        let result = try ConceptRendering.renderAll(
            concepts.plans, runID: manifest.runID, aspect: manifest.aspectRatio, photos: photos,
            features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }),
            stylePack: try StylePackLoader.load(id: concepts.stylePackID), sourceFolder: folder, into: staging,
            seedOverride: seed, storyHint: manifest.storyHint, exactSet: manifest.exactSet, keepOrder: manifest.keepOrder)
        guard !result.failed else {
            try? fm.removeItem(at: staging)
            throw Failure.render(result.warnings)
        }
        // Swap output directories together: move current output aside, move staged in, roll back on any failure.
        // `layouts` (legacy resolved-slide plans) only exists for non-recipe concepts and `documents`
        // (CanvasDocuments, spec §3) only for recipe-filled ones, so neither is required on either side.
        let dirs = ["slides", "layouts", "documents"]
        let backup = store.url(".rerender-backup")
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var moved: [String] = []
        do {
            for dir in dirs where fm.fileExists(atPath: store.url(dir).path) {
                try fm.moveItem(at: store.url(dir), to: backup.appending(path: dir)); moved.append(dir)
            }
            for dir in dirs where fm.fileExists(atPath: staging.appending(path: dir).path) {
                try fm.moveItem(at: staging.appending(path: dir), to: store.url(dir))
            }
        } catch {
            for dir in dirs { try? fm.removeItem(at: store.url(dir)) }
            for dir in moved { try? fm.moveItem(at: backup.appending(path: dir), to: store.url(dir)) }
            try? fm.removeItem(at: staging); try? fm.removeItem(at: backup)
            throw error
        }
        try? fm.removeItem(at: staging); try? fm.removeItem(at: backup)
        concepts.renderedSlides = result.slides
        try store.write(concepts, to: "plans/director.json")
    }

    /// Shared original-photo resolution and integrity check for rerender and engine evaluation.
    static func verifiedSource(_ source: URL, photos: [AssetID: PhotoRecord], assetIDs: [AssetID]) throws -> URL {
        let folder = source.resolvingSymlinksInPath()
        // Unknown IDs (e.g. a hand-edited plan) are dropped by the resolver with a warning.
        for id in Set(assetIDs).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let p = photos[id] else { continue }
            let sha = try FileHasher.sha256Hex(of: folder.appending(path: p.sourceRelativePaths[0]))
            if sha != p.contentSHA256 { throw Failure.changed(p.sourceRelativePaths[0]) }
        }
        return folder
    }
}
