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
    /// `recompose` first re-runs the composer engine on the stored directions (legacy plans without one are kept).
    static func rerender(runDirectory: URL, source: URL, seed: UInt64? = nil, recompose: Bool = false) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let ingest = try store.read(IngestResult.self, from: "input-index.json")
        let features = try store.read([PhotoFeatures].self, from: "cache/features.json")
        var concepts = try store.read(ConceptsReport.self, from: "plans/director.json")
        guard !concepts.plans.isEmpty else { throw Failure.noPlans }
        if recompose, let spine = concepts.spine {
            // Replays each plan's own direction and seed under its own id. Carousels already edited or handed off
            // keep their plan, so edits, snapshots and study metrics stay comparable to the original.
            let fm = FileManager.default
            let touched = Set(concepts.plans.map(\.id).filter { id in
                fm.fileExists(atPath: store.url("edits/\(id)").path)
                    || ((try? fm.contentsOfDirectory(atPath: store.url("handoffs").path)) ?? []).contains { $0.hasPrefix("\(id)-") }
            })
            let context = try RunSession(runDirectory: runDirectory).compositionContext()
            let fresh = ComposerEngine.recompose(concepts.plans.filter { !touched.contains($0.id) }, context: context,
                                                 runID: manifest.runID)
            concepts.plans = concepts.plans.map { p in fresh.first { $0.id == p.id } ?? p }
            for id in touched.sorted() { concepts.warnings.append("\(id): not recomposed (it has edits or a hand-off)") }
            let directions = concepts.plans.filter { !$0.isBaseline }
            concepts.diversity = directions.indices.flatMap { i in directions.indices.filter { $0 > i }.map { j in
                PlanMetrics.diversity(directions[i], directions[j]) } }
            concepts.deviations = Dictionary(uniqueKeysWithValues: directions.map { ($0.id, PlanMetrics.deviation(plan: $0, spine: spine)) })
            for p in concepts.plans { try store.write(p, to: "plans/\(p.id).json") }
        }
        let photos = Dictionary(uniqueKeysWithValues: ingest.photos.map { ($0.assetID, $0) })
        let folder = source.resolvingSymlinksInPath()
        // Unknown IDs (e.g. a hand-edited plan) are dropped by the resolver with a warning; verify only known photos.
        for id in Set(concepts.plans.flatMap(\.photoAssetIDs)) {
            guard let p = photos[id] else { continue }
            let sha = try FileHasher.sha256Hex(of: folder.appending(path: p.sourceRelativePaths[0]))
            if sha != p.contentSHA256 { throw Failure.changed(p.sourceRelativePaths[0]) }
        }
        let fm = FileManager.default
        let staging = store.url(".rerender")
        try? fm.removeItem(at: staging)
        let result = try ConceptRendering.renderAll(
            concepts.plans, runID: manifest.runID, aspect: manifest.aspectRatio, photos: photos,
            features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }),
            stylePack: try StylePackLoader.load(id: concepts.stylePackID), sourceFolder: folder, into: staging,
            seedOverride: seed)
        guard !result.failed else {
            try? fm.removeItem(at: staging)
            throw Failure.render(result.warnings)
        }
        // Swap both directories together: move current output aside, move staged in, roll back on any failure.
        let backup = store.url(".rerender-backup")
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var moved: [String] = []
        do {
            for dir in ["slides", "layouts"] where fm.fileExists(atPath: store.url(dir).path) {
                try fm.moveItem(at: store.url(dir), to: backup.appending(path: dir)); moved.append(dir)
            }
            for dir in ["slides", "layouts"] { try fm.moveItem(at: staging.appending(path: dir), to: store.url(dir)) }
        } catch {
            for dir in ["slides", "layouts"] { try? fm.removeItem(at: store.url(dir)) }
            for dir in moved { try? fm.moveItem(at: backup.appending(path: dir), to: store.url(dir)) }
            try? fm.removeItem(at: staging); try? fm.removeItem(at: backup)
            throw error
        }
        try? fm.removeItem(at: staging); try? fm.removeItem(at: backup)
        concepts.renderedSlides = result.slides
        try store.write(concepts, to: "plans/director.json")
    }
}
