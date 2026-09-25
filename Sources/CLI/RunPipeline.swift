import Analysis
import Core
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct RunPipeline: Sendable {
    let ingester: any PhotoIngesting
    let thumbnailer: Thumbnailer
    let analyzer: any PhotoAnalyzing
    let cache: AnalysisCache
    let log: @Sendable (String) -> Void

    static func live(options: RunOptions,
                     log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    -> RunPipeline {
        RunPipeline(ingester: FolderIngester(),
                    thumbnailer: Thumbnailer(cacheRoot: options.cacheDirectory),
                    analyzer: VisionAnalyzer(cacheRoot: options.cacheDirectory),
                    // Features are computed from thumbnails, so both versions key the cache.
                    cache: AnalysisCache(root: options.cacheDirectory,
                                         analyzerVersion: "\(VisionAnalyzer.version)+\(Thumbnailer.version)"),
                    log: log)
    }

    func run(_ options: RunOptions, now: Date = Date()) async throws -> RunStore {
        let clock = ContinuousClock()
        var timings: [StageTiming] = []
        var warnings: [String] = []

        // 1. Ingest
        var start = clock.now
        let ingest = try await ingester.ingest(
            folder: options.folder,
            options: IngestOptions(recursive: options.recursive,
                                   excludedDirectories: [options.runsDirectory, options.cacheDirectory]))
        timings.append(StageTiming(stage: "ingest", seconds: (clock.now - start).seconds))
        log("Finding the best moments… \(ingest.photos.count) photos, \(ingest.skipped.count) skipped")

        // 2. Analysis-tier thumbnails (cached across runs)
        start = clock.now
        let thumbnailer = self.thumbnailer
        let folder = options.folder.resolvingSymlinksInPath()
        // RAW decodes are full-size before downsampling; keep fewer in flight to bound memory.
        let hasRAW = ingest.photos.contains { UTType($0.fileType)?.conforms(to: .rawImage) == true }
        let thumbURLs: [URL?] = try await ingest.photos.concurrentMap(limit: hasRAW ? 2 : 4) { p in
            try? thumbnailer.thumbnail(sha: p.contentSHA256, source: folder.appending(path: p.sourceRelativePaths[0]),
                                       tier: .analysis)
        }
        var thumbByID: [AssetID: URL] = [:]
        for (p, url) in zip(ingest.photos, thumbURLs) {
            if let url { thumbByID[p.assetID] = url } else { warnings.append("thumbnail failed: \(p.sourceRelativePaths[0])") }
        }
        timings.append(StageTiming(stage: "thumbnails", seconds: (clock.now - start).seconds))

        // 3. Vision features (cached by content digest + analyzer version)
        start = clock.now
        var features: [AssetID: PhotoFeatures] = [:]
        var pending: [(PhotoRecord, URL)] = []
        for p in ingest.photos {
            guard let url = thumbByID[p.assetID] else { continue }
            if let cached = cache.load(sha: p.contentSHA256) { features[p.assetID] = cached } else { pending.append((p, url)) }
        }
        let hits = features.count
        log("Analyzing \(pending.count) photos (\(hits) cached)…")
        let analyzer = self.analyzer
        let fresh = try await pending.concurrentMap(limit: 4) { pair in await analyzer.analyze(pair.0, thumbnailURL: pair.1) }
        for ((p, _), f) in zip(pending, fresh) {
            features[p.assetID] = f
            if f.failures.isEmpty {
                do { try cache.store(f, sha: p.contentSHA256) } catch {
                    warnings.append("could not cache analysis for \(p.sourceRelativePaths[0])")
                }
            } else {
                warnings.append("analysis incomplete for \(p.sourceRelativePaths[0]): \(f.failures.keys.sorted().joined(separator: ", "))")
            }
        }
        timings.append(StageTiming(stage: "analysis", seconds: (clock.now - start).seconds))

        // 4. Run directory
        let store = try RunStore.create(in: options.runsDirectory, runID: RunID.make(now: now))
        var thumbRel: [AssetID: String] = [:]
        for (id, url) in thumbByID.sorted(by: { $0.key < $1.key }) {
            let rel = "cache/thumbnails/analysis/\(id.rawValue).jpg"
            let target = store.url(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            thumbRel[id] = rel
        }

        var manifest = RunManifest(runID: store.root.lastPathComponent, createdAt: now,
                                   sourceFolderLabel: options.folder.lastPathComponent)
        manifest.inputDigest = Self.inputDigest(ingest.photos)
        manifest.photoCount = ingest.photos.count
        manifest.skippedCount = ingest.skipped.count
        manifest.aspectRatio = options.aspect ?? CarouselAspect.infer(from: ingest.photos)
        manifest.aspectOverridden = options.aspect != nil
        manifest.versions = ["analyzer": VisionAnalyzer.version, "thumbnailer": Thumbnailer.version,
                             "report": ReportBuilder.version, "manifestSchema": "\(RunManifest.currentSchemaVersion)"]
        manifest.stageTimings = timings
        manifest.cacheHits = hits
        manifest.cacheMisses = pending.count
        manifest.warnings = warnings
        manifest.completedAt = now.addingTimeInterval(timings.reduce(0) { $0 + $1.seconds })

        let redacted = IngestResult(photos: ingest.photos.map { $0.redactingLocation() }, skipped: ingest.skipped)
        try store.write(redacted, to: "input-index.json")
        try store.write(ingest.photos.compactMap { features[$0.assetID] }, to: "cache/features.json")
        try store.write(manifest, to: "manifest.json")
        try store.writeText(ReportBuilder.html(ReportInput(manifest: manifest, photos: redacted.photos, skipped: ingest.skipped,
                                                           features: features, thumbnails: thumbRel)),
                            to: "report.html")
        log("Report: \(store.url("report.html").path)")
        return store
    }

    static func inputDigest(_ photos: [PhotoRecord]) -> String {
        let joined = photos.map(\.contentSHA256).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
