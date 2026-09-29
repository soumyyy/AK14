import Analysis
import Core
import Director
import Foundation
import Render

struct StoryOption: Identifiable, Sendable {
    let id: String
    let title: String
    let slides: [URL]
    let stylePackPin: StylePackPin
    let generationMode: GenerationMode
    let runDirectory: URL
    let sourceFolder: URL
    /// True when the run attempted model-assisted planning (the caller asked for it and a client was
    /// configured). Combined with `generationMode == .photosOnly`, this means the AI produced nothing
    /// usable — the fallback banner shows only in that case, not when the owner simply left AI off.
    var modelAssistRequested: Bool = false

    enum GenerationMode: String, Codable, Sendable { case photosOnly, modelDirected }
}

/// Mobile orchestration around the same local analysis, reduction, composition and render stages as the CLI.
/// A ResponsesClient is injected by the app when available; it is never created from an embedded credential.
struct StoryPipeline: Sendable {
    let responsesClient: ResponsesClient?
    let stylePackProvider: (@Sendable () async throws -> LoadedStylePack)?

    init(responsesClient: ResponsesClient? = nil,
         stylePackProvider: (@Sendable () async throws -> LoadedStylePack)? = nil) {
        self.responsesClient = responsesClient
        self.stylePackProvider = stylePackProvider
    }

    func run(folder: URL, modelAssist: Bool, importDuration: Double = 0,
             eventAssetIDs: Set<AssetID>? = nil, storyHint: String? = nil,
             eventSegments: [EventSegment]? = nil,
             occasionResult: OccasionSplitter.Result? = nil,
             exactSet: Bool = false, keepOrder: Bool = false,
             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [StoryOption] {
        let clock = ContinuousClock()
        var timings: [StageTiming] = []
        if let occasionResult { timings.append(StageTiming(stage: "occasion_split", seconds: occasionResult.call.latencySeconds)) }
        var stageStart = clock.now
        let ingest = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
        timings.append(StageTiming(stage: "import", seconds: importDuration + (clock.now - stageStart).seconds))
        guard !ingest.photos.isEmpty else { throw PipelineFailure.noPhotos }
        let events = exactSet ? [] : (eventSegments ?? EventSegmenter.segment(ingest.photos))
        let chosenEvent = eventAssetIDs.flatMap { ids in events.first { Set($0.assetIDs) == ids }?.index }
        // FolderIngester intentionally returns a stable identity-sorted result. For an explicit
        // keep-order request, recover the caller's sequence from the ordered import filenames
        // (the Share Extension writes photo-0000, photo-0001, … in selection order).
        let orderedExactPhotos = exactSet && keepOrder
            ? ingest.photos.sorted {
                ($0.sourceRelativePaths.first ?? "") < ($1.sourceRelativePaths.first ?? "")
            }
            : ingest.photos
        let photos = exactSet ? orderedExactPhotos : (eventAssetIDs.map { ids in ingest.photos.filter { ids.contains($0.assetID) } } ?? ingest.photos)
        guard !photos.isEmpty else { throw PipelineFailure.noPhotos }
        let photoByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        let support = try Self.applicationSupport()
        let cacheRoot = support.appending(path: "analysis-cache", directoryHint: .isDirectory)
        let thumbnailer = Thumbnailer(cacheRoot: cacheRoot)
        progress("Preparing photo thumbnails · 0 of \(photos.count)")
        var analysisURLs: [(PhotoRecord, URL)] = []
        for (offset, photo) in photos.enumerated() {
            try Task.checkCancellation()
            let source = folder.appending(path: photo.sourceRelativePaths[0])
            let thumbnail = try thumbnailer.thumbnail(sha: photo.contentSHA256, source: source, tier: .analysis)
            analysisURLs.append((photo, thumbnail))
            progress("Preparing photo thumbnails · \(offset + 1) of \(photos.count)")
        }
        stageStart = clock.now
        let analyzer = VisionAnalyzer(cacheRoot: cacheRoot)
        progress("Analyzing photos on device · 0 of \(analysisURLs.count)")
        let analysisProgress = StageProgress()
        let totalAnalysis = analysisURLs.count
        let featuresList = await analysisURLs.asyncMap(limit: 3) { pair in
            let features = await analyzer.analyze(pair.0, thumbnailURL: pair.1)
            let completed = await analysisProgress.advance()
            progress("Analyzing photos on device · \(completed) of \(totalAnalysis)")
            return features
        }
        try Task.checkCancellation()
        timings.append(StageTiming(stage: "analysis", seconds: (clock.now - stageStart).seconds))
        stageStart = clock.now
        let features = Dictionary(uniqueKeysWithValues: featuresList.map { ($0.assetID, $0) })
        let index = FeaturePrintIndex(cacheRoot: cacheRoot, features: features)
        var reduction = ReductionResult.reduce(photos: photos, features: features, distance: index.distance)
        if exactSet {
            let ranked = Dictionary(uniqueKeysWithValues: reduction.ranked.map { ($0.assetID, $0) })
            reduction.shortlist = photos.compactMap { ranked[$0.assetID] }
        }
        guard exactSet || !reduction.shortlist.isEmpty else { throw PipelineFailure.noUsablePhotos }
        timings.append(StageTiming(stage: "reduction", seconds: (clock.now - stageStart).seconds))

        let loadedStylePack = try await stylePackProvider?()
        let stylePack = try loadedStylePack?.stylePack ?? StylePackLoader.load()
        let stylePackPin = loadedStylePack?.pin ?? StylePackPin(id: stylePack.id, version: stylePack.version)
        let aspect = CarouselAspect.infer(from: photos)
        let runID = RunID.make(now: Date())
        let runsRoot = support.appending(path: "runs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        let stagingRoot = runsRoot.appending(path: ".staging-\(runID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        let store = RunStore.open(stagingRoot)
        let runRoot = stagingRoot
        var completedRun = false
        defer {
            if !completedRun { try? FileManager.default.removeItem(at: runRoot) }
        }
        var warnings: [String] = []
        var plans: [CarouselPlan]
        var presentationOrder: [String]
        let generationMode: StoryOption.GenerationMode
        var providerCalls: [ProviderCallRecord] = occasionResult.map { [$0.call] } ?? []

        let designedLibrary: DesignedSetLibrary?
        do {
            let loaded = try StylePackLoader.loadDesignedSets()
            if let issue = loaded.validationError() {
                warnings.append("Designed layouts unavailable: \(issue)")
                designedLibrary = nil
            } else { designedLibrary = loaded }
        } catch {
            warnings.append("Designed layouts unavailable: \(error.localizedDescription)")
            designedLibrary = nil
        }
        let vocabulary = designedLibrary?.vocabulary(for: aspect) ?? []

        stageStart = clock.now
        if modelAssist, let client = responsesClient {
            progress("Preparing a private photo summary for the model…")
            let candidates = exactSet ? [] : reduction.triageCandidates(photos: photos, features: features)
            let candidateIDs = exactSet ? photos.map(\.assetID) : candidates.map(\.assetID)
            async let triageURLsTask = thumbnailerURLs(candidateIDs, photos: photoByID, folder: folder, thumbnailer: thumbnailer,
                                                       tier: .triage, progressName: "Preparing triage thumbnails", progress: progress)
            async let planningURLsTask = thumbnailerURLs(candidateIDs, photos: photoByID, folder: folder, thumbnailer: thumbnailer,
                                                         tier: .planning, progressName: "Preparing planning thumbnails", progress: progress)
            let (triageURLs, planningURLs) = try await (triageURLsTask, planningURLsTask)
            let eventStart = candidateIDs.compactMap { photoByID[$0]?.metadata.capturedAt }.min()
            let cards = candidateIDs.compactMap { id -> CandidateCard? in
                guard let photo = photoByID[id] else { return nil }
                let relativeDay: String
                if let date = photo.metadata.capturedAt, let start = eventStart {
                    relativeDay = "day \(max(1, Int(date.timeIntervalSince(start) / 86_400) + 1))"
                } else { relativeDay = "day unknown" }
                var summary = [photo.orientation.rawValue,
                    ShapeClass.of(aspect: Double(photo.pixelWidth) / Double(max(photo.pixelHeight, 1))).rawValue,
                    relativeDay]
                if let labels = features[id]?.labels.prefix(3).map(\.identifier), !labels.isEmpty {
                    summary.append(labels.joined(separator: ", "))
                }
                if let faces = features[id]?.faces, !faces.isEmpty {
                    summary.append(faces.count == 1 ? "1 face" : "\(faces.count) faces")
                }
                let photoSummary = summary.joined(separator: " · ")
                return CandidateCard(assetID: id, summary: photoSummary,
                                     capturedAt: photo.metadata.capturedAt,
                                     triageJPEG: triageURLs[id].flatMap { try? Data(contentsOf: $0) },
                                     planningJPEG: planningURLs[id].flatMap { try? Data(contentsOf: $0) })
            }
            let poolCount = min(candidates.count, max(8, min(30, candidates.count / 2)))
            let reductionConfig = reduction.config
            let candidatePhotos = photoByID
            let poolSelector: @Sendable ([AssetID: TriageScore]) -> [AssetID] = { triage in
                if exactSet { return keepOrder ? photos.map(\.assetID) : candidateIDs }
                return DiversitySelector.selectPlanningPool(ranked: candidates, triage: triage, target: poolCount,
                                                     photos: candidatePhotos, features: features, distance: index.distance,
                                                     config: reductionConfig).map(\.assetID)
            }
            let dateSpan: String
            let dates = candidateIDs.compactMap { photoByID[$0]?.metadata.capturedAt }
            if let first = dates.min(), let last = dates.max() {
                let days = Int(last.timeIntervalSince(first) / 86_400) + 1
                dateSpan = days == 1 ? "a single day" : "\(days) days"
            } else { dateSpan = "duration unknown" }
            let context = CompositionContext(aspect: aspect, photos: photoByID, features: features, triage: [:],
                                             flagged: [], sequenceIntent: [:], stylePack: stylePack, maxSlides: nil,
                                             exactSet: exactSet, keepOrder: keepOrder, storyHint: modelAssist ? storyHint : nil,
                                             vocabulary: vocabulary)
            progress("Building options…")
            var directorInput = DirectorInput(storyLabel: "a personal event", dateSpan: dateSpan, requestedSlides: nil,
                              shortlist: cards, selectPool: poolSelector, composition: context, runID: runID,
                              storyHint: modelAssist ? storyHint : nil,
                              allowMultiEventRecap: !exactSet && eventSegments.map { $0.count > 1 } == true && eventAssetIDs == nil,
                              exactSet: exactSet, keepOrder: keepOrder)
            if exactSet { directorInput.maxPlanningImages = cards.count }
            let output = await ArtDirector(client: client, stylePack: stylePack).direct(directorInput)
            guard !output.plans.isEmpty else { throw PipelineFailure.directorProducedNoPlans }
            providerCalls += output.calls
            let adjusted = exactSet ? [] : CandidateRanker.applyTriage(candidates, triage: output.triage, config: reductionConfig)
            let adjustedByID = Dictionary(uniqueKeysWithValues: adjusted.map { ($0.assetID, $0) })
            reduction.planningPool = output.pool.compactMap { adjustedByID[$0] }
            reduction.funnel.shortlisted = candidateIDs.count
            reduction.funnel.triaged = output.triage.count
            reduction.funnel.planningPool = output.pool.count
            plans = output.plans
            presentationOrder = output.presentationOrder.isEmpty ? output.plans.map(\.id) : output.presentationOrder
            warnings = output.warnings
            let elapsed = (clock.now - stageStart).seconds
            let modelSeconds = output.calls.reduce(0) { $0 + $1.latencySeconds }
            timings.append(StageTiming(stage: "director", seconds: min(elapsed, modelSeconds)))
            timings.append(StageTiming(stage: "composition", seconds: max(0, elapsed - modelSeconds)))
            generationMode = output.plans.contains { !$0.isBaseline } ? .modelDirected : .photosOnly
        } else {
            progress("Composing local options…")
            let exactRankedIDs = reduction.ranked.map(\.assetID)
            let rankedThenRemaining = exactRankedIDs + photos.map(\.assetID).filter { !Set(exactRankedIDs).contains($0) }
            let ordered = exactSet ? (keepOrder ? photos.map(\.assetID) : rankedThenRemaining)
                : Array(reduction.shortlist.map(\.assetID).prefix(10))
            let spine = SelectionSpine(orderedAssetIDs: ordered,
                                       sequenceIntent: ordered.indices.map { index in
                                           index == 0 ? .opener : index == ordered.count - 1 ? .closer : .build
                                       },
                                       rationale: [])
            let context = CompositionContext(aspect: aspect, photos: photoByID, features: features, triage: [:],
                                             flagged: [], sequenceIntent: Dictionary(uniqueKeysWithValues: zip(ordered, spine.sequenceIntent)),
                                             stylePack: stylePack, maxSlides: nil, exactSet: exactSet, keepOrder: keepOrder,
                                             vocabulary: vocabulary)
            let set = ComposerEngine.composeSet(directions: [], spine: spine, context: context, runID: runID)
            plans = set.plans
            timings.append(StageTiming(stage: "director", seconds: 0))
            timings.append(StageTiming(stage: "composition", seconds: (clock.now - stageStart).seconds))
            presentationOrder = set.presentationOrder
            warnings = set.warnings
            generationMode = .photosOnly
        }

        try store.write(ingest.photos.map { $0.redactingLocation() }, to: "input-index.json")
        try store.write(featuresList, to: "cache/features.json")
        try store.write(reduction, to: "cache/reduction.json")
        try store.write(stylePack, to: "style-pack.json")
        try store.write(stylePackPin, to: "style-pack-pin.json")
        try store.write(aspect, to: "aspect.json")
        // Imports live under this app's Application Support; keep only the relative import ID in
        // the run so its stored artifacts never expose a device-specific absolute path.
        try store.writeText(folder.lastPathComponent, to: "source-import-id.txt")
        try store.write(plans, to: "plans/options.json")
        try store.write(presentationOrder, to: "plans/presentation-order.json")
        if let occasionResult {
            try store.write(JSONValue.object([("request", occasionResult.exchange.request),
                                              ("response", occasionResult.exchange.response ?? .null)]),
                            to: "llm/0-occasion-split.json")
        }

        stageStart = clock.now
        var byID: [String: [URL]] = [:]
        for (optionIndex, plan) in plans.enumerated() {
            try Task.checkCancellation()
            progress("Rendering option \(optionIndex + 1) of \(plans.count) · \(plan.slides.count) slides")
            let layout = LayoutContext(aspect: aspect, photos: photoByID, features: features, stylePack: stylePack,
                                       seed: ComposerEngine.layoutSeed(runID: runID, id: plan.id),
                                       vocabulary: plan.isBaseline ? [] : vocabulary)
            let resolved = LayoutResolver.resolve(plan, context: layout)
            let directory = runRoot.appending(path: "slides/\(plan.id)", directoryHint: .isDirectory)
            let result = try CarouselRenderer().render(resolved, photos: photoByID, sourceFolder: folder,
                                                       outputDirectory: directory)
            guard result.failures.isEmpty, !result.names.isEmpty else { throw PipelineFailure.renderFailed(result.failures.joined(separator: "; ")) }
            byID[plan.id] = result.names.map { directory.appending(path: $0) }
            try store.write(resolved.slides, to: "layouts/\(plan.id)/slides.json")
            var document = CanvasDocument(from: resolved, photos: photoByID)
            document.recipeID = plan.recipeID
            document.stylePackPin = stylePackPin.id
            try store.write(document, to: "documents/\(plan.id).json")
            try store.write(document, to: "documents/originals/\(plan.id).json")
            progress("Rendered option \(optionIndex + 1) of \(plans.count)")
        }
        let attemptedModelAssist = modelAssist && responsesClient != nil
        let options = presentationOrder.compactMap { id -> StoryOption? in
            guard let slides = byID[id], !slides.isEmpty else { return nil }
            return StoryOption(id: id, title: "Option \((presentationOrder.firstIndex(of: id) ?? 0) + 1)",
                               slides: slides, stylePackPin: stylePackPin,
                               generationMode: generationMode, runDirectory: runRoot, sourceFolder: folder,
                               modelAssistRequested: attemptedModelAssist)
        }
        guard !options.isEmpty else { throw PipelineFailure.renderFailed(warnings.joined(separator: "; ")) }
        try Task.checkCancellation()
        timings.append(StageTiming(stage: "render", seconds: (clock.now - stageStart).seconds))
        var manifest = RunManifest(runID: runID, createdAt: Date(), sourceFolderLabel: folder.lastPathComponent)
        manifest.photoCount = photos.count
        manifest.exactSet = exactSet
        manifest.events = events.map(EventSegmentSummary.init)
        manifest.chosenEvent = chosenEvent
        manifest.storyHint = storyHint
        manifest.aspectRatio = aspect
        manifest.stageTimings = timings
        manifest.warnings = warnings
        manifest.directorStatus = generationMode == .modelDirected ? "ok" : "skipped: photos only"
        manifest.providerCalls = providerCalls
        manifest.totalEstimatedCost = providerCalls.reduce(0) { $0 + $1.estimatedCost }
        manifest.completedAt = Date()
        try store.write(manifest, to: "manifest.json")
        let finalRoot = runsRoot.appending(path: runID, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: stagingRoot, to: finalRoot)
        let promotedOptions = options.map { option in
            StoryOption(id: option.id, title: option.title, slides: option.slides.map { finalRoot.appending(path: $0.path.replacingOccurrences(of: stagingRoot.path + "/", with: "")) }, stylePackPin: option.stylePackPin, generationMode: option.generationMode, runDirectory: finalRoot, sourceFolder: option.sourceFolder, modelAssistRequested: option.modelAssistRequested)
        }
        completedRun = true
        return promotedOptions
    }

    static func deleteRun(for option: StoryOption) throws {
        let support = try applicationSupport()
        let runsRoot = support.appending(path: "runs", directoryHint: .isDirectory).standardizedFileURL
        let importsRoot = support.appending(path: "imports", directoryHint: .isDirectory).standardizedFileURL
        let runDirectory = option.runDirectory.standardizedFileURL
        let sourceFolder = option.sourceFolder.standardizedFileURL
        guard runDirectory.deletingLastPathComponent() == runsRoot,
              sourceFolder.deletingLastPathComponent() == importsRoot else { return }
        try FileManager.default.removeItem(at: runDirectory)
        try FileManager.default.removeItem(at: sourceFolder)
    }

    static func cleanupStaleStaging() {
        guard let support = try? applicationSupport() else { return }
        let runsRoot = support.appending(path: "runs", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func thumbnailerURLs(_ candidateIDs: [AssetID], photos: [AssetID: PhotoRecord], folder: URL,
                                 thumbnailer: Thumbnailer, tier: ThumbnailTier, progressName: String,
                                 progress: @escaping @Sendable (String) -> Void) throws -> [AssetID: URL] {
        var result: [AssetID: URL] = [:]
        for (offset, id) in candidateIDs.enumerated() {
            try Task.checkCancellation()
            guard let photo = photos[id] else { continue }
            let source = folder.appending(path: photo.sourceRelativePaths[0])
            result[id] = try? thumbnailer.thumbnail(sha: photo.contentSHA256, source: source, tier: tier)
            progress("\(progressName) · \(offset + 1) of \(candidateIDs.count)")
        }
        return result
    }

    static func applicationSupport() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appending(path: "AK14", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum PipelineFailure: LocalizedError {
        case noPhotos, noUsablePhotos, directorProducedNoPlans, renderFailed(String)
        var errorDescription: String? {
            switch self {
            case .noPhotos: "No readable photos were found in the import."
            case .noUsablePhotos: "No photos passed the local quality checks."
            case .directorProducedNoPlans: "The option planner did not return any layouts."
            case .renderFailed(let detail): "Could not render the options. \(detail)"
            }
        }
    }
}

private actor StageProgress {
    private var completed = 0
    func advance() -> Int { completed += 1; return completed }
}

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(limit: Int, _ transform: @escaping @Sendable (Element) async -> T) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            var next = 0
            var values = [T?](repeating: nil, count: count)
            for _ in 0..<Swift.min(limit, count) {
                let index = next; next += 1
                group.addTask { (index, await transform(self[index])) }
            }
            while let (index, value) = await group.next() {
                values[index] = value
                if next < count {
                    let index = next; next += 1
                    group.addTask { (index, await transform(self[index])) }
                }
            }
            return values.map { $0! }
        }
    }
}
