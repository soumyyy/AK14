import Analysis
import Core
import CryptoKit
import Director
import Foundation
import Render
import Session
import UniformTypeIdentifiers

struct RunPipeline: Sendable {
    let ingester: any PhotoIngesting
    let thumbnailer: Thumbnailer
    let analyzer: any PhotoAnalyzing
    let cache: AnalysisCache
    /// nil = no API key; the Director stage is skipped.
    let client: ResponsesClient?
    let log: @Sendable (String) -> Void

    static func live(options: RunOptions, client: ResponsesClient? = nil,
                     log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    -> RunPipeline {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resolved = client ?? Env.apiKey(cwd: cwd).map { ResponsesClient(transport: OpenAITransport(apiKey: $0)) }
        return RunPipeline(ingester: FolderIngester(),
                           thumbnailer: Thumbnailer(cacheRoot: options.cacheDirectory),
                           analyzer: VisionAnalyzer(cacheRoot: options.cacheDirectory),
                           // Features are computed from thumbnails, so both versions key the cache.
                           cache: AnalysisCache(root: options.cacheDirectory,
                                                analyzerVersion: "\(VisionAnalyzer.version)+\(Thumbnailer.version)"),
                           client: resolved, log: log)
    }

    func run(_ options: RunOptions, now: Date = Date()) async throws -> RunStore {
        let clock = ContinuousClock()
        var timings: [StageTiming] = []
        var warnings: [String] = []
        func lap(_ stage: String, _ start: ContinuousClock.Instant) { timings.append(StageTiming(stage: stage, seconds: (clock.now - start).seconds)) }

        // 1. Ingest
        var start = clock.now
        let ingest = try await ingester.ingest(
            folder: options.folder,
            options: IngestOptions(recursive: options.recursive,
                                   excludedDirectories: [options.runsDirectory, options.cacheDirectory]))
        lap("ingest", start)
        log("Finding the best moments… \(ingest.photos.count) photos, \(ingest.skipped.count) skipped")

        // 2. Analysis-tier thumbnails (cached across runs)
        start = clock.now
        let folder = options.folder.resolvingSymlinksInPath()
        let thumbByID = try await thumbnails(ingest.photos, tier: .analysis, folder: folder, warnings: &warnings)
        lap("thumbnails", start)

        // 3. Vision features (cached by content digest + analyzer/thumbnailer version)
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
        lap("analysis", start)

        // 4. Reduction: clusters → junk → rank → diverse shortlist
        start = clock.now
        let config = ReductionConfig()
        let index = FeaturePrintIndex(cacheRoot: options.cacheDirectory, features: features)
        var reduction = ReductionResult.reduce(photos: ingest.photos, features: features, distance: index.distance, config: config)
        lap("reduction", start)
        log("Reduced to \(reduction.shortlist.count) candidates from \(reduction.funnel.representatives) distinct moments")

        // 5. Run directory
        let store = try RunStore.create(in: options.runsDirectory, runID: RunID.make(now: now))
        var thumbRel: [AssetID: String] = [:]
        for (id, url) in thumbByID.sorted(by: { $0.key < $1.key }) {
            let rel = "cache/thumbnails/analysis/\(id.rawValue).jpg"
            let target = store.url(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            thumbRel[id] = rel
        }
        let aspect = options.aspect ?? CarouselAspect.infer(from: ingest.photos)

        // 6. Director (triage → pool → planning) and Plain render
        var concepts: ConceptsReport?
        var calls: [ProviderCallRecord] = []
        var directorStatus: String
        var versions = ["analyzer": VisionAnalyzer.version, "thumbnailer": Thumbnailer.version,
                        "report": ReportBuilder.version, "manifestSchema": "\(RunManifest.currentSchemaVersion)",
                        "reduction": config.version]
        if options.noLLM {
            directorStatus = "skipped: --no-llm"
        } else if client == nil {
            directorStatus = "skipped: no OPENAI_API_KEY"
        } else if reduction.shortlist.isEmpty {
            directorStatus = "skipped: no usable photos"
        } else {
            start = clock.now
            let stylePack = try StylePackLoader.load()
            let output = try await direct(reduction: reduction, photos: ingest.photos, features: features,
                                                   index: index, folder: folder, options: options, stylePack: stylePack,
                                                   warnings: &warnings)
            lap("director", start)
            calls = output.calls
            directorStatus = output.status
            versions["pricing"] = Pricing.version
            versions["model"] = client!.model
            versions["stylePack"] = "\(stylePack.id)@\(stylePack.version)"
            versions["resolver"] = ResolvedCarousel.resolverVersion
            versions["renderer"] = CarouselRenderer.version
            for (name, v) in output.promptVersions { versions["prompt:\(name)"] = v }

            // Persist raw exchanges (images redacted to thumbnail references) and plans.
            for e in output.exchanges {
                try store.write(JSONValue.object([("request", e.request), ("response", e.response ?? .null)]), to: "llm/\(e.name).json")
            }
            reduction = Self.applyDirector(output, to: reduction, config: config)
            if let spine = output.spine { try store.write(spine, to: "plans/selection-spine.json") }
            for p in output.plans { try store.write(p, to: "plans/\(p.conceptType.rawValue).json") }

            // Resolve + render every concept
            start = clock.now
            log("Rendering your options…")
            var rendered: [String: [String]] = [:]
            do {
                let result = try ConceptRendering.renderAll(
                    output.plans, runID: store.root.lastPathComponent, aspect: aspect,
                    photos: Dictionary(uniqueKeysWithValues: ingest.photos.map { ($0.assetID, $0) }),
                    features: features, stylePack: stylePack, sourceFolder: folder, into: store.root)
                rendered = result.slides
                warnings += result.warnings
            } catch {
                warnings.append("render failed: \(error)")
            }
            lap("render", start)
            warnings += output.warnings
            concepts = ConceptsReport(
                status: output.status, stylePackID: stylePack.id, stylePackVersion: stylePack.version,
                triage: Dictionary(uniqueKeysWithValues: output.triage.map { ($0.key.rawValue, $0.value) }),
                pool: output.pool, spine: output.spine, recommendedSlideCount: output.recommendedSlideCount,
                plans: output.plans, unavailable: output.unavailable, deviations: output.deviations,
                diversity: output.diversity, warnings: output.warnings, renderedSlides: rendered)
            try store.write(concepts, to: "plans/director.json")
        }

        // 7. Manifest + report
        var manifest = RunManifest(runID: store.root.lastPathComponent, createdAt: now,
                                   sourceFolderLabel: options.folder.lastPathComponent)
        manifest.inputDigest = Self.inputDigest(ingest.photos)
        manifest.photoCount = ingest.photos.count
        manifest.skippedCount = ingest.skipped.count
        manifest.aspectRatio = aspect
        manifest.aspectOverridden = options.aspect != nil
        manifest.versions = versions
        manifest.stageTimings = timings
        manifest.cacheHits = hits
        manifest.cacheMisses = pending.count
        manifest.funnel = reduction.funnel
        manifest.directorStatus = directorStatus
        manifest.providerCalls = calls
        manifest.totalEstimatedCost = calls.reduce(0) { $0 + $1.estimatedCost }
        if manifest.totalEstimatedCost > 0.5 {
            warnings.append(String(format: "estimated model cost $%.3f exceeds the $0.50 soft cap", manifest.totalEstimatedCost))
        }
        manifest.warnings = warnings
        manifest.completedAt = Date()

        let redacted = IngestResult(photos: ingest.photos.map { $0.redactingLocation() }, skipped: ingest.skipped)
        try store.write(redacted, to: "input-index.json")
        try store.write(ingest.photos.compactMap { features[$0.assetID] }, to: "cache/features.json")
        try store.write(reduction, to: "cache/reduction.json")
        try store.write(manifest, to: "manifest.json")
        try store.writeText(ReportBuilder.html(ReportInput(manifest: manifest, photos: redacted.photos, skipped: ingest.skipped,
                                                           features: features, thumbnails: thumbRel,
                                                           reduction: reduction, concepts: concepts)),
                            to: "report.html")
        log(String(format: "Director: %@ · %d model calls · est. $%.4f", directorStatus, calls.count, manifest.totalEstimatedCost))
        log("Report: \(store.url("report.html").path)")
        return store
    }

    // MARK: - Stages

    private func thumbnails(_ photos: [PhotoRecord], tier: ThumbnailTier, folder: URL,
                            warnings: inout [String]) async throws -> [AssetID: URL] {
        let thumbnailer = self.thumbnailer
        // RAW decodes are full-size before downsampling; keep fewer in flight to bound memory.
        let hasRAW = photos.contains { UTType($0.fileType)?.conforms(to: .rawImage) == true }
        let urls: [URL?] = try await photos.concurrentMap(limit: hasRAW ? 2 : 4) { p in
            try? thumbnailer.thumbnail(sha: p.contentSHA256, source: folder.appending(path: p.sourceRelativePaths[0]), tier: tier)
        }
        var out: [AssetID: URL] = [:]
        for (p, url) in zip(photos, urls) {
            if let url { out[p.assetID] = url } else { warnings.append("\(tier.rawValue) thumbnail failed: \(p.sourceRelativePaths[0])") }
        }
        return out
    }

    private func direct(reduction: ReductionResult, photos: [PhotoRecord], features: [AssetID: PhotoFeatures],
                        index: FeaturePrintIndex, folder: URL, options: RunOptions, stylePack: StylePack,
                        warnings: inout [String]) async throws -> DirectorOutput {
        let photoByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        let shortlistPhotos = reduction.shortlist.compactMap { photoByID[$0.assetID] }
        let triageThumbs = try await thumbnails(shortlistPhotos, tier: .triage, folder: folder, warnings: &warnings)
        let planningThumbs = try await thumbnails(shortlistPhotos, tier: .planning, folder: folder, warnings: &warnings)
        let junk = Dictionary(uniqueKeysWithValues: reduction.junk.map { ($0.assetID, $0) })
        let start = shortlistPhotos.compactMap(\.metadata.capturedAt).min()

        let cards = reduction.shortlist.map { c in
            CandidateCard(assetID: c.assetID,
                          summary: Self.summary(c, photo: photoByID[c.assetID], features: features[c.assetID],
                                                junk: junk[c.assetID], eventStart: start),
                          capturedAt: photoByID[c.assetID]?.metadata.capturedAt,
                          triageJPEG: triageThumbs[c.assetID].flatMap { try? Data(contentsOf: $0) },
                          planningJPEG: planningThumbs[c.assetID].flatMap { try? Data(contentsOf: $0) },
                          localFlags: Self.localSafetyFlags(features[c.assetID]))
        }

        let shortlist = reduction.shortlist, config = reduction.config
        let planning = ReductionTargets.forUsable(reduction.ranked.count).planning
        let poolTarget = min(shortlist.count, options.slides.map { min(planning.upperBound, max(planning.lowerBound, $0 * 4)) }
                             ?? (planning.lowerBound + planning.upperBound) / 2)
        let selectPool: @Sendable ([AssetID: TriageScore]) -> [AssetID] = { triage in
            let adjusted = CandidateRanker.applyTriage(shortlist, triage: triage, config: config)
            return DiversitySelector.select(ranked: adjusted, target: poolTarget, photos: photoByID, features: features,
                                            distance: index.distance, config: config).map(\.assetID)
        }
        let dates = shortlistPhotos.compactMap(\.metadata.capturedAt)
        var span = "dates unknown"
        if let first = dates.min(), let last = dates.max() {
            let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX")
            span = "\(f.string(from: first)) – \(f.string(from: last))"
        }

        let director = ArtDirector(client: client!, stylePack: stylePack, log: log)
        return await director.direct(DirectorInput(storyLabel: options.folder.lastPathComponent, dateSpan: span,
                                                   requestedSlides: options.slides, shortlist: cards, selectPool: selectPool))
    }

    /// Updates rank scores with triage, records the planning pool and funnel counts.
    static func applyDirector(_ output: DirectorOutput, to reduction: ReductionResult, config: ReductionConfig) -> ReductionResult {
        var r = reduction
        let adjusted = CandidateRanker.applyTriage(r.shortlist, triage: output.triage, config: config)
        let byID = Dictionary(uniqueKeysWithValues: adjusted.map { ($0.assetID, $0) })
        r.shortlist = r.shortlist.map { old in
            var new = byID[old.assetID] ?? old
            new.selectionReason = old.selectionReason
            return new
        }
        r.planningPool = output.pool.compactMap { byID[$0] }
        r.funnel.triaged = output.triage.count
        r.funnel.planningPool = output.pool.count
        r.funnel.selected = output.spine?.orderedAssetIDs.count ?? 0
        return r
    }

    /// Outlier-low face-capture quality on a close-up (1–2 faces) counts as a social-safety flag for covers.
    /// Capture quality is relative and runs low for small faces (median ≈0.14 on real group-heavy events),
    /// so only clear outliers are flagged.
    static func localSafetyFlags(_ f: PhotoFeatures?) -> [String] {
        guard let faces = f?.faces, (1...2).contains(faces.count) else { return [] }
        return faces.contains { ($0.captureQuality ?? 1) <= 0.05 } ? ["lowFaceQuality"] : []
    }

    /// One line of local facts for the model. Times are relative to the event start (no absolute location).
    static func summary(_ c: RankedCandidate, photo: PhotoRecord?, features f: PhotoFeatures?,
                        junk: JunkDisposition?, eventStart: Date?) -> String {
        var parts: [String] = []
        if let t = photo?.metadata.capturedAt, let s = eventStart {
            let minutes = Int(t.timeIntervalSince(s) / 60)
            parts.append("day \(minutes / 1440 + 1) +\(minutes % 1440 / 60)h\(String(format: "%02d", minutes % 60))m")
        } else { parts.append("time unknown") }
        if let p = photo { parts.append(p.orientation.rawValue) }
        if let f {
            if !f.faces.isEmpty {
                let q = f.faces.compactMap(\.captureQuality)
                parts.append("\(f.faces.count) face\(f.faces.count == 1 ? "" : "s")" + (q.isEmpty ? "" : String(format: " (quality %.2f)", q.reduce(0, +) / Double(q.count))))
            }
            let labels = f.labels.prefix(4).map(\.identifier)
            if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
            if let s = f.sharpness { parts.append(s < 0.03 ? "soft/blurry" : "sharp") }
            if let d = f.darkFraction, d > 0.6 { parts.append("dark") }
        }
        if c.clusterSize > 1 { parts.append("best of \(c.clusterSize) similar frames") }
        if let junk, junk.verdict == .penalize { parts.append("flags: " + junk.reasons.joined(separator: " ")) }
        if photo?.metadata.cameraModel == nil { parts.append("received/forwarded") }
        return parts.joined(separator: " · ")
    }

    static func inputDigest(_ photos: [PhotoRecord]) -> String {
        let joined = photos.map(\.contentSHA256).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
