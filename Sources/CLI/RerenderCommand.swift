import Analysis
import Core
import Foundation
import Render

enum RerenderCommand {
    enum Failure: Error, CustomStringConvertible {
        case noPlan, changed(String)
        var description: String {
            switch self {
            case .noPlan: "run has no Plain Dump plan to render"
            case .changed(let p): "source photo changed since the run: \(p)"
            }
        }
    }

    /// Re-renders the Plain Dump from saved plans and the source folder. Never calls the model.
    static func rerender(runDirectory: URL, source: URL) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let ingest = try store.read(IngestResult.self, from: "input-index.json")
        let features = try store.read([PhotoFeatures].self, from: "cache/features.json")
        guard let plain = try? store.read(CarouselPlan.self, from: "plans/plainDump.json") else { throw Failure.noPlan }
        let photos = Dictionary(uniqueKeysWithValues: ingest.photos.map { ($0.assetID, $0) })
        let folder = source.resolvingSymlinksInPath()
        for id in plain.photoAssetIDs {
            guard let p = photos[id] else { throw Failure.changed(id.rawValue) }
            let sha = try FileHasher.sha256Hex(of: folder.appending(path: p.sourceRelativePaths[0]))
            if sha != p.contentSHA256 { throw Failure.changed(p.sourceRelativePaths[0]) }
        }
        try? FileManager.default.removeItem(at: store.url("slides/plainDump"))
        _ = try PlainRenderer().render(plan: plain, aspect: manifest.aspectRatio, photos: photos,
                                       features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }),
                                       sourceFolder: folder, outputDirectory: store.url("slides/plainDump"))
    }
}
