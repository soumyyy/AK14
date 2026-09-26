import Analysis
import Core
import Foundation
import Render

enum StoryEditingFailure: Error, LocalizedError, Sendable {
    case unavailableOption(String)
    case missingPhoto(AssetID)
    case changedSource(String)
    case renderFailed([String])
    case noRenderedSlides(String)

    var errorDescription: String? {
        switch self {
        case .unavailableOption(let id): "Option \(id) is not in this run."
        case .missingPhoto(let id): "Photo \(id) is not in this run's source index."
        case .changedSource(let path): "Source photo is missing or changed: \(path)"
        case .renderFailed(let messages): "The edited option could not be rendered. " + messages.prefix(3).joined(separator: "; ")
        case .noRenderedSlides(let id): "Option \(id) has no rendered slides."
        }
    }
}

/// Applies the small set of supported edits to one generated option and atomically installs a new edited copy.
/// The original option, source plans, slides, layouts, and presentation order remain untouched.
actor StoryEditingService {
    let runDirectory: URL
    let sourceFolder: URL

    private let store: RunStore
    private let runID: String
    private let aspect: CarouselAspect
    private let photos: [AssetID: PhotoRecord]
    private let features: [AssetID: PhotoFeatures]
    private let reduction: ReductionResult?
    private let stylePack: StylePack
    private let stylePackPin: StylePackPin
    private let originalPlans: [String: CarouselPlan]

    init(runDirectory: URL, sourceFolder: URL) throws {
        self.runDirectory = runDirectory.standardizedFileURL
        self.sourceFolder = sourceFolder.resolvingSymlinksInPath().standardizedFileURL
        store = RunStore.open(runDirectory)
        runID = runDirectory.lastPathComponent

        let photoList = try store.read([PhotoRecord].self, from: "input-index.json")
        photos = Dictionary(uniqueKeysWithValues: photoList.map { ($0.assetID, $0) })
        features = Dictionary(uniqueKeysWithValues: try store.read([PhotoFeatures].self, from: "cache/features.json")
            .map { ($0.assetID, $0) })
        reduction = try? store.read(ReductionResult.self, from: "cache/reduction.json")
        stylePack = try store.read(StylePack.self, from: "style-pack.json")
        stylePackPin = try store.read(StylePackPin.self, from: "style-pack-pin.json")
        aspect = (try? store.read(CarouselAspect.self, from: "aspect.json")) ?? .infer(from: photoList)
        let plans = try store.read([CarouselPlan].self, from: "plans/options.json")
        guard plans.allSatisfy({ Self.isSafeOptionID($0.id) }) else {
            throw StoryEditingFailure.unavailableOption("invalid option ID")
        }
        originalPlans = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })

        guard FileManager.default.fileExists(atPath: self.sourceFolder.path) else {
            throw StoryEditingFailure.changedSource(self.sourceFolder.path)
        }
        try Self.recoverInterruptedEdits(in: self.runDirectory)
    }

    /// Returns the current edited render when present, otherwise the original render.
    func slideURLs(for optionID: String) throws -> [URL] {
        guard originalPlans[optionID] != nil else { throw StoryEditingFailure.unavailableOption(optionID) }
        let edited = store.url("edits/\(optionID)/slides")
        let original = store.url("slides/\(optionID)")
        let directory = FileManager.default.fileExists(atPath: edited.path) ? edited : original
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.sorted()
        guard !names.isEmpty else { throw StoryEditingFailure.noRenderedSlides(optionID) }
        return names.map { directory.appending(path: $0) }
    }

    /// Current edit-or-original plan for this option.
    func plan(for optionID: String) throws -> CarouselPlan {
        guard let original = originalPlans[optionID] else { throw StoryEditingFailure.unavailableOption(optionID) }
        return (try? store.read(CarouselPlan.self, from: "edits/\(optionID)/plan.json")) ?? original
    }

    /// Swap choices in relevance order: same shot-cluster alternates first, then the planning pool.
    /// Photos already used in the option and local junk rejects are omitted.
    func swapCandidates(for optionID: String, replacing photoID: AssetID) throws -> [PhotoRecord] {
        guard originalPlans[optionID] != nil else { throw StoryEditingFailure.unavailableOption(optionID) }
        let current = try self.plan(for: optionID)
        let used = Set(current.photoAssetIDs)
        let cluster = reduction?.clusters.first { $0.memberAssetIDs.contains(photoID) }?.memberAssetIDs ?? []
        let pool: [RankedCandidate]
        if let reduction { pool = reduction.planningPool.isEmpty ? reduction.shortlist : reduction.planningPool }
        else { pool = [] }
        let rejected = Set(reduction?.junk.filter { $0.verdict == .reject }.map(\.assetID) ?? [])
        var seen = Set<AssetID>()
        let ids = (cluster + pool.map(\.assetID)).filter { id in
            !used.contains(id) && !rejected.contains(id) && seen.insert(id).inserted
        }
        return ids.compactMap { photos[$0] }
    }

    /// Applies one PlanEdit and returns the resulting PNG URLs in slide order.
    /// For swaps, every source used by the updated option is re-hashed before rendering.
    func apply(_ edit: PlanEdit, to optionID: String) throws -> [URL] {
        let current = try plan(for: optionID)
        var edited = try PlanEditor.apply(edit, to: current)
        if current.isBaseline {
            edited.slides = edited.slides.map { slide in
                var slide = slide
                slide.decorations = []
                slide.stamps = []
                return slide
            }
        }

        try verifySources(for: edited)
        let layoutContext = LayoutContext(aspect: aspect, photos: photos, features: features, stylePack: stylePack,
                                          seed: ComposerEngine.layoutSeed(runID: runID, id: optionID))
        let resolved = LayoutResolver.resolve(edited, context: layoutContext)
        let stagingRoot = store.url("edits/.staging/\(UUID().uuidString)")
        let stagedOption = stagingRoot.appending(path: "new", directoryHint: .isDirectory)
        let backup = stagingRoot.appending(path: "previous", directoryHint: .isDirectory)
        let final = store.url("edits/\(optionID)")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try fileManager.createDirectory(at: stagedOption, withIntermediateDirectories: true)
        try store.writeText(optionID, to: "edits/.staging/\(stagingRoot.lastPathComponent)/option-id.txt")
        try store.write(edited, to: "edits/.staging/\(stagingRoot.lastPathComponent)/new/plan.json")
        try store.write(stylePackPin, to: "edits/.staging/\(stagingRoot.lastPathComponent)/new/style-pack-pin.json")
        try store.write(resolved.slides, to: "edits/.staging/\(stagingRoot.lastPathComponent)/new/layouts/slides.json")
        let render = try CarouselRenderer().render(resolved, photos: photos, sourceFolder: sourceFolder,
                                                  outputDirectory: stagedOption.appending(path: "slides", directoryHint: .isDirectory))
        guard render.failures.isEmpty, !render.names.isEmpty else {
            throw StoryEditingFailure.renderFailed(render.failures)
        }

        var originalMoved = false
        do {
            if fileManager.fileExists(atPath: final.path) {
                try fileManager.moveItem(at: final, to: backup)
                originalMoved = true
            }
            try fileManager.moveItem(at: stagedOption, to: final)
        } catch {
            if originalMoved, !fileManager.fileExists(atPath: final.path) {
                try? fileManager.moveItem(at: backup, to: final)
            }
            throw error
        }
        return render.names.map { final.appending(path: "slides/\($0)") }
    }

    private func verifySources(for plan: CarouselPlan) throws {
        for id in Set(plan.photoAssetIDs) {
            guard let photo = photos[id] else { throw StoryEditingFailure.missingPhoto(id) }
            guard let relative = photo.sourceRelativePaths.first else { throw StoryEditingFailure.missingPhoto(id) }
            let source = sourceFolder.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
            let prefix = sourceFolder.path.hasSuffix("/") ? sourceFolder.path : sourceFolder.path + "/"
            guard source.path.hasPrefix(prefix),
                  let digest = try? FileHasher.sha256Hex(of: source), digest == photo.contentSHA256 else {
                throw StoryEditingFailure.changedSource(relative)
            }
        }
    }

    /// If a process stops between the two directory renames, restore the prior edit when the final is absent.
    private static func recoverInterruptedEdits(in runDirectory: URL) throws {
        let fileManager = FileManager.default
        let staging = runDirectory.appending(path: "edits/.staging", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: staging.path) else { return }
        let entries = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            guard let optionID = try? String(contentsOf: entry.appending(path: "option-id.txt"), encoding: .utf8),
                  isSafeOptionID(optionID) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let final = runDirectory.appending(path: "edits/\(optionID)")
            let backup = entry.appending(path: "previous")
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: final.path) {
                try fileManager.moveItem(at: backup, to: final)
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func isSafeOptionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
