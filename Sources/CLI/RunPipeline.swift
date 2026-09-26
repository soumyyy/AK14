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

        var events = options.exact ? [] : EventSegmenter.segment(ingest.photos)
        if options.event != nil && options.allEvents { throw ArgumentError.invalidValue("--event", "cannot be combined with --all-events") }
        var photos = ingest.photos

        // 2. Analysis-tier thumbnails (cached across runs)
        start = clock.now
        let folder = options.folder.resolvingSymlinksInPath()
        var thumbByID = try await thumbnails(photos, tier: .analysis, folder: folder, warnings: &warnings)
        lap("thumbnails", start)

        // 3. Vision features (cached by content digest + analyzer/thumbnailer version)
        start = clock.now
        var features: [AssetID: PhotoFeatures] = [:]
        var pending: [(PhotoRecord, URL)] = []
        for p in photos {
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

        // Refine timestamp groups with the on-device Vision scene signatures before selection.
        if !options.exact { events = EventSegmenter.segment(ingest.photos, features: features) }
        var occasionResult: OccasionSplitter.Result?
        if !options.exact && options.consent && !options.noLLM, let client {
            occasionResult = await OccasionSplitter.split(events: events, photos: ingest.photos,
                                                           thumbnails: thumbByID, features: features, client: client)
            if let occasionResult {
                events = occasionResult.events
                timings.append(StageTiming(stage: "occasion_split", seconds: occasionResult.call.latencySeconds))
            }
        }
        if !options.exact, let requested = options.event, !events.contains(where: { $0.index == requested }) {
            throw ArgumentError.invalidEvent("\(requested) (found \(events.count) events)")
        }
        let chosenEvent: Int? = options.exact || options.allEvents ? nil : (options.event ?? events.max(by: { $0.photoCount < $1.photoCount })?.index)
        let selectedIDs = chosenEvent.flatMap { id in events.first(where: { $0.index == id })?.assetIDs }
        if let selectedIDs {
            let selected = Set(selectedIDs)
            photos = ingest.photos.filter { selected.contains($0.assetID) }
            thumbByID = thumbByID.filter { selected.contains($0.key) }
            features = features.filter { selected.contains($0.key) }
        }
        if options.event == nil && !options.allEvents && events.count > 1 {
            log("Found \(events.count) events:")
            for event in events {
                let dates = event.start.map { Self.eventDate($0) } ?? "undated"
                let end = event.end.map { Self.eventDate($0) } ?? dates
                log("  Event \(event.index): \(dates)–\(end), \(event.photoCount) photos")
            }
            log("Using the largest event. Choose another with --event N, or use --all-events for one story across everything.")
        }

        // 4. Reduction: clusters → junk → rank → diverse shortlist
        start = clock.now
        let config = ReductionConfig()
        let index = FeaturePrintIndex(cacheRoot: options.cacheDirectory, features: features)
        var reduction = ReductionResult.reduce(photos: photos, features: features, distance: index.distance, config: config)
        if options.exact {
            let junk = Dictionary(uniqueKeysWithValues: reduction.junk.map { ($0.assetID, $0) })
            let exactClusters = ShotClusterer.cluster(photos: photos, features: features, distance: { _, _ in nil }, config: config)
            let exactRanked = CandidateRanker.rank(photos: photos, features: features, clusters: exactClusters,
                                                   junk: junk, config: config)
            reduction.ranked = exactRanked
            reduction.shortlist = exactRanked
            reduction.funnel.representatives = exactRanked.count
            reduction.funnel.shortlisted = exactRanked.count
        }
        lap("reduction", start)
        log(options.exact ? "Exact set: \(reduction.shortlist.count) photos for planning" : "Reduced to \(reduction.shortlist.count) candidates from \(reduction.funnel.representatives) distinct moments")

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
        let aspect = options.aspect ?? CarouselAspect.infer(from: photos)
        // Written immediately (completedAt = nil) so an interrupted run is visible as incomplete, never counted.
        var early = RunManifest(runID: store.root.lastPathComponent, createdAt: now, sourceFolderLabel: options.folder.lastPathComponent)
        early.studyCode = options.studyCode
        early.exactSet = options.exact
        try store.write(early, to: "manifest.json")
        try store.write(IngestResult(photos: ingest.photos.map { $0.redactingLocation() }, skipped: ingest.skipped), to: "input-index.json")

        // 6. Director (triage → pool → planning) and Plain render
        var concepts: ConceptsReport?
        var calls: [ProviderCallRecord] = occasionResult.map { [$0.call] } ?? []
        var directorStatus: String
        var versions = ["analyzer": VisionAnalyzer.version, "thumbnailer": Thumbnailer.version,
                        "report": ReportBuilder.version, "manifestSchema": "\(RunManifest.currentSchemaVersion)",
                        "reduction": config.version]
        if let occasionResult {
            versions["prompt:occasion-split.system"] = occasionResult.promptVersion
            versions["model"] = client?.model ?? "unknown"
            versions["pricing"] = Pricing.version
            try store.write(JSONValue.object([("request", occasionResult.exchange.request),
                                              ("response", occasionResult.exchange.response ?? .null)]),
                            to: "llm/0-occasion-split.json")
        }
        if options.noLLM {
            directorStatus = "skipped: --no-llm"
        } else if !options.consent {
            directorStatus = "skipped: no consent"
        } else if client == nil {
            directorStatus = "skipped: no OPENAI_API_KEY"
        } else if reduction.shortlist.isEmpty {
            directorStatus = "skipped: no usable photos"
        } else {
            start = clock.now
            let stylePack = try StylePackLoader.load()
            let output = try await direct(reduction: reduction, photos: photos, features: features,
                                                   index: index, folder: folder, options: options, stylePack: stylePack,
                                                   aspect: aspect, runID: store.root.lastPathComponent, warnings: &warnings)
            lap("director", start)
            calls += output.calls
            directorStatus = output.status
            versions["pricing"] = Pricing.version
            versions["model"] = client!.model
            versions["stylePack"] = "\(stylePack.id)@\(stylePack.version)"
            versions["resolver"] = ResolvedCarousel.resolverVersion
            versions["composer"] = ComposerEngine.version
            versions["renderer"] = CarouselRenderer.version
            for (name, v) in output.promptVersions { versions["prompt:\(name)"] = v }

            // Persist raw exchanges (images redacted to thumbnail references) and plans.
            for e in output.exchanges {
                try store.write(JSONValue.object([("request", e.request), ("response", e.response ?? .null)]), to: "llm/\(e.name).json")
            }
            let triageCandidates = reduction.triageCandidates(photos: photos, features: features)
            reduction = Self.applyDirector(output, to: reduction, triageCandidates: triageCandidates, config: config)
            if let spine = output.spine { try store.write(spine, to: "plans/selection-spine.json") }
            for p in output.plans { try store.write(p, to: "plans/\(p.id).json") }

            // Resolve + render every concept
            start = clock.now
            log("Rendering your options…")
            var rendered: [String: [String]] = [:]
            do {
                let result = try ConceptRendering.renderAll(
                    output.plans, runID: store.root.lastPathComponent, aspect: aspect,
                    photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) }),
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
                diversity: output.diversity, warnings: output.warnings, renderedSlides: rendered,
                presentationOrder: output.presentationOrder)
            concepts?.requestedSlides = options.slides
            try store.write(concepts, to: "plans/director.json")
        }

        // 7. Manifest + report
        var manifest = RunManifest(runID: store.root.lastPathComponent, createdAt: now,
                                   sourceFolderLabel: options.folder.lastPathComponent)
        manifest.inputDigest = Self.inputDigest(ingest.photos)
        manifest.photoCount = photos.count
        manifest.events = events.map(EventSegmentSummary.init)
        manifest.chosenEvent = chosenEvent
        manifest.storyHint = options.story
        manifest.exactSet = options.exact
        manifest.skippedCount = ingest.skipped.count
        manifest.aspectRatio = aspect
        manifest.aspectOverridden = options.aspect != nil
        manifest.versions = versions
        manifest.stageTimings = timings
        manifest.cacheHits = hits
        manifest.cacheMisses = pending.count
        manifest.funnel = reduction.funnel
        manifest.studyCode = options.studyCode
        if options.consent && !options.noLLM {
            manifest.consent = Consent(acknowledgedAt: now, disclosureVersion: Disclosure.version)
        }
        manifest.directorStatus = directorStatus
        manifest.providerCalls = calls
        manifest.totalEstimatedCost = calls.reduce(0) { $0 + $1.estimatedCost }
        if manifest.totalEstimatedCost > 0.5 {
            warnings.append(String(format: "estimated model cost $%.3f exceeds the $0.50 soft cap", manifest.totalEstimatedCost))
        }
        manifest.warnings = warnings
        manifest.completedAt = Date()

        let redacted = IngestResult(photos: photos.map { $0.redactingLocation() }, skipped: ingest.skipped)
        try store.write(redacted, to: "input-index.json")
        try store.write(photos.compactMap { features[$0.assetID] }, to: "cache/features.json")
        try store.write(reduction, to: "cache/reduction.json")
        try store.write(manifest, to: "manifest.json")
        try store.writeText(ReportBuilder.html(ReportInput(manifest: manifest, photos: redacted.photos, skipped: ingest.skipped,
                                                           features: features, thumbnails: thumbRel,
                                                           reduction: reduction, concepts: concepts,
                                                           layouts: store.layouts(concepts))),
                            to: "report.html")
        log(String(format: "Director: %@ · %d model calls · est. $%.4f", directorStatus, calls.count, manifest.totalEstimatedCost))
        log("Report: \(store.url("report.html").path)")
        return store
    }

    private static func eventDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
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
                        aspect: CarouselAspect, runID: String, warnings: inout [String]) async throws -> DirectorOutput {
        let photoByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        let triageCandidates = options.exact ? reduction.shortlist : reduction.triageCandidates(photos: photos, features: features)
        let shortlistPhotos = triageCandidates.compactMap { photoByID[$0.assetID] }
        let triageThumbs = try await thumbnails(shortlistPhotos, tier: .triage, folder: folder, warnings: &warnings)
        let planningThumbs = try await thumbnails(shortlistPhotos, tier: .planning, folder: folder, warnings: &warnings)
        let junk = Dictionary(uniqueKeysWithValues: reduction.junk.map { ($0.assetID, $0) })
        let start = shortlistPhotos.compactMap(\.metadata.capturedAt).min()

        let cards = triageCandidates.map { c in
            CandidateCard(assetID: c.assetID,
                          summary: Self.summary(c, photo: photoByID[c.assetID], features: features[c.assetID],
                                                junk: junk[c.assetID], eventStart: start),
                          capturedAt: photoByID[c.assetID]?.metadata.capturedAt,
                          triageJPEG: triageThumbs[c.assetID].flatMap { try? Data(contentsOf: $0) },
                          planningJPEG: planningThumbs[c.assetID].flatMap { try? Data(contentsOf: $0) },
                          localFlags: Self.localSafetyFlags(features[c.assetID]))
        }

        let shortlist = triageCandidates, config = reduction.config
        let planning = ReductionTargets.forUsable(reduction.ranked.count).planning
        let poolTarget = min(shortlist.count, options.slides.map { min(planning.upperBound, max(planning.lowerBound, $0 * 4)) }
                             ?? (planning.lowerBound + planning.upperBound) / 2)
        let selectPool: @Sendable ([AssetID: TriageScore]) -> [AssetID] = { triage in
            if options.exact {
                let ordered = options.keepOrder ? photos.sorted { $0.sourceRelativePaths[0] < $1.sourceRelativePaths[0] }.map(\.assetID) : shortlist.map(\.assetID)
                return ordered.filter { id in shortlist.contains(where: { $0.assetID == id }) }
            }
            return DiversitySelector.selectPlanningPool(ranked: shortlist, triage: triage, target: poolTarget,
                                                 photos: photoByID, features: features, distance: index.distance,
                                                 config: config).map(\.assetID)
        }
        // Only the event's length is sent: no folder name (it may contain a study code or a name) and no calendar dates.
        let dates = shortlistPhotos.compactMap(\.metadata.capturedAt)
        var span = "duration unknown"
        if let first = dates.min(), let last = dates.max() {
            let days = Int(last.timeIntervalSince(first) / 86_400) + 1
            span = days <= 1 ? "a single day" : "\(days) days"
        }

        let composition = CompositionContext(aspect: aspect, photos: photoByID, features: features, triage: [:], flagged: [],
                                             sequenceIntent: [:], stylePack: stylePack, maxSlides: options.slides,
                                             exactSet: options.exact, keepOrder: options.keepOrder)
        let director = ArtDirector(client: client!, stylePack: stylePack, log: log)
        return await director.direct(DirectorInput(storyLabel: "a personal event", dateSpan: span,
                                                   requestedSlides: options.slides, shortlist: cards, selectPool: selectPool,
                                                   composition: composition, runID: runID, storyHint: options.story,
                                                   allowMultiEventRecap: options.allEvents, exactSet: options.exact, keepOrder: options.keepOrder))
    }

    /// Updates rank scores with triage, records the planning pool and funnel counts.
    static func applyDirector(_ output: DirectorOutput, to reduction: ReductionResult,
                              triageCandidates: [RankedCandidate], config: ReductionConfig) -> ReductionResult {
        var r = reduction
        let adjusted = CandidateRanker.applyTriage(triageCandidates, triage: output.triage, config: config)
        let byID = Dictionary(uniqueKeysWithValues: adjusted.map { ($0.assetID, $0) })
        r.shortlist = r.shortlist.map { old in
            var new = byID[old.assetID] ?? old
            new.selectionReason = old.selectionReason
            return new
        }
        r.planningPool = output.pool.compactMap { byID[$0] }
        r.funnel.shortlisted = triageCandidates.count
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
