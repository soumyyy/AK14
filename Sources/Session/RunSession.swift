import CryptoKit
import Core
import Foundation
import Render

/// Everything Studio does to a run: load it, apply the allowed edits, re-render, export, and log behaviour.
///
/// - Edits live in `edits/<concept>/` (`plan.json`, `seed.txt`, `slides/`, `layouts/`), swapped in as one directory
///   rename, so a concept's plan and images always match. The run's `plans/` and `slides/` are never modified.
/// - Mutating operations are serialized: a second edit waits for the first, so plans and the event log agree.
/// - The report is rebuilt after every operation, so edits and events show up in report.html.
public final class RunSession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case noConcepts, noSource, sourceChanged(String), unavailable(String), render([String]), nothingToExport
        public var description: String {
            switch self {
            case .noConcepts: "this run has no concepts (it was made with --no-llm or the model was skipped)"
            case .noSource: "choose the run's source photo folder first"
            case .sourceChanged(let p): "source photo changed or is missing: \(p)"
            case .unavailable(let c): "\(c) is not available in this run"
            case .render(let f): "render failed: \(f.prefix(3).joined(separator: "; "))"
            case .nothingToExport: "this concept has no rendered slides to export"
            }
        }
    }

    public let root: URL
    public let manifest: RunManifest
    public let concepts: ConceptsReport
    public let photos: [AssetID: PhotoRecord]
    public let features: [AssetID: PhotoFeatures]
    public let reduction: ReductionResult?
    public let stylePack: StylePack
    public let log: InteractionLog
    private let store: RunStore
    /// Guards the mutable state below (short, never held across rendering).
    private let state = NSLock()
    /// Serializes whole mutating operations (render + commit + log).
    private let operation = NSLock()
    private var _sourceFolder: URL?
    private var working: [String: CarouselPlan] = [:]
    private var seeds: [String: UInt64] = [:]

    public init(runDirectory: URL) throws {
        root = runDirectory
        store = RunStore.open(runDirectory)
        manifest = try store.read(RunManifest.self, from: "manifest.json")
        guard let c = try? store.read(ConceptsReport.self, from: "plans/director.json"), !c.plans.isEmpty else { throw Failure.noConcepts }
        concepts = c
        photos = Dictionary(uniqueKeysWithValues: try store.read(IngestResult.self, from: "input-index.json").photos.map { ($0.assetID, $0) })
        features = Dictionary(uniqueKeysWithValues: try store.read([PhotoFeatures].self, from: "cache/features.json").map { ($0.assetID, $0) })
        reduction = try? store.read(ReductionResult.self, from: "cache/reduction.json")
        stylePack = try StylePackLoader.load(id: c.stylePackID)
        log = InteractionLog(url: runDirectory.appending(path: "interaction-events.jsonl"))
        for id in c.plans.map(\.id) {
            if let p = try? store.read(CarouselPlan.self, from: "edits/\(id)/plan.json") { working[id] = p }
            if let text = try? String(contentsOf: store.url("edits/\(id)/seed.txt"), encoding: .utf8),
               let s = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) { seeds[id] = s }
        }
        try? FileManager.default.removeItem(at: store.url("edits/.staging"))   // leftovers from an interrupted edit
    }

    public var runID: String { manifest.runID }
    /// Carousel ids in presentation order (the baseline is shuffled in among the directions, unlabeled).
    public var availableConcepts: [String] { concepts.orderedPlans.map(\.id) }
    public var sourceFolder: URL? { state.withLock { _sourceFolder } }

    /// Verifies the photos used by any concept and the candidate pool against their recorded content hashes.
    /// Swap alternates outside that set are verified individually when chosen.
    public func setSource(_ folder: URL) throws {
        let folder = folder.resolvingSymlinksInPath()
        for id in Set(concepts.plans.flatMap(\.photoAssetIDs) + concepts.pool) { try verify(id, in: folder) }
        state.withLock { _sourceFolder = folder }
    }

    // MARK: - Reading

    public func plan(_ c: String) -> CarouselPlan? {
        state.withLock { working[c] } ?? concepts.plan(c)
    }

    public func isEdited(_ c: String) -> Bool { state.withLock { working[c] != nil } }

    /// Current slide images: edited output when present, else the run's original render.
    public func slideURLs(_ c: String) -> [URL] {
        if isEdited(c) {
            let dir = root.appending(path: "edits/\(c)/slides")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()) ?? []
            return names.map { dir.appending(path: $0) }
        }
        return (concepts.renderedSlides[c] ?? []).map { root.appending(path: $0) }
    }

    public func thumbnailURL(_ id: AssetID) -> URL { root.appending(path: "cache/thumbnails/analysis/\(id.rawValue).jpg") }

    /// Swap candidates: the photo's own shot-cluster alternates first, then the planning pool,
    /// excluding photos already in the concept and junk rejects.
    public func swapCandidates(_ c: String, photo: AssetID) -> [AssetID] {
        let used = Set(plan(c)?.photoAssetIDs ?? [])
        let cluster = reduction?.clusters.first { $0.memberAssetIDs.contains(photo) }?.memberAssetIDs ?? []
        let rejected = Set(reduction?.junk.filter { $0.verdict == .reject }.map(\.assetID) ?? [])
        var seen = Set<AssetID>(), out: [AssetID] = []
        for id in cluster + concepts.pool where !used.contains(id) && !rejected.contains(id) && photos[id] != nil {
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    // MARK: - Edits (serialized)

    public func apply(_ edit: PlanEdit, to c: String, source: String = "operator") throws {
        try operation.withLock {
            guard let current = plan(c) else { throw Failure.unavailable(c) }
            var edited = try PlanEditor.apply(edit, to: current)
            if current.isBaseline { edited.slides = edited.slides.map { var s = $0; s.decorations = []; s.stamps = []; return s } }
            if case .swap(_, _, let new) = edit, let folder = sourceFolder { try verify(new, in: folder) }
            try commit(edited, c, seed: state.withLock { seeds[c] })

            let slideKey = { (p: CarouselPlan) in p.slides.map { $0.photos.map(\.assetID.rawValue).joined(separator: "+") } }
            switch edit {
            case .reorder(let from, let to):
                try record("slide_reordered", c, slide: to, assets: current.slides[from].photos.map(\.assetID),
                           before: slideKey(current), after: slideKey(edited), source: source)
            case .swap(let s, let old, let new):
                try record("photo_swapped", c, slide: s, assets: [old, new], before: [old.rawValue], after: [new.rawValue], source: source)
            case .remove(let s, let id):
                try record("photo_removed", c, slide: s, assets: [id], before: [id.rawValue], after: [], source: source)
            }
            if current.coverAssetID != edited.coverAssetID, let old = current.coverAssetID, let new = edited.coverAssetID {
                try record("cover_changed", c, slide: 0, assets: [old, new], before: [old.rawValue], after: [new.rawValue], source: source)
            }
            try? RunReport.rebuild(runDirectory: root)
        }
    }

    /// Recomposes the carousel with a new seed, no model call: the composer engine regroups the current photos
    /// (keeping swaps and removals) under the same direction. Legacy plans without a direction only get new geometry.
    /// The seed is only kept if the render succeeds.
    public func reroll(_ c: String, source: String = "operator") throws {
        try operation.withLock {
            guard let current = plan(c) else { throw Failure.unavailable(c) }
            let seed = SeededRandom.seed(runID, c, UUID().uuidString)
            var next = current
            if var direction = current.direction {
                let ids = current.photoAssetIDs
                direction.orderedAssetIDs = ids
                if let cover = current.coverAssetID { direction.coverAssetID = cover }
                direction.keepTogether = direction.keepTogether.filter { $0.allSatisfy(ids.contains) }
                direction.emphasisAssetIDs = direction.emphasisAssetIDs.filter(ids.contains)
                next = ComposerEngine.compose(direction, id: c, context: compositionContext(), seed: seed).plan
            }
            try commit(next, c, seed: seed)
            try record("concept_rerolled", c, source: source)
            try? RunReport.rebuild(runDirectory: root)
        }
    }

    // MARK: - Behaviour logging (no source folder needed)

    public func select(_ c: String, source: String = "operator") throws {
        try operation.withLock { try record("concept_selected", c, source: source); try? RunReport.rebuild(runDirectory: root) }
    }
    public func presented(source: String = "operator") throws {
        try operation.withLock { try record("concepts_presented", nil, source: source) }
    }
    /// Call only after the share actually completed (not when a service was merely picked).
    public func shared(_ c: String, service: String, source: String = "operator") throws {
        try operation.withLock {
            let snapshot = try snapshotHandoff(c)
            try record("carousel_shared", c, after: [service, "snapshot=\(snapshot)"], source: source)
            try? RunReport.rebuild(runDirectory: root)
        }
    }

    /// Saves exactly what was handed to the participant, so study metrics score the handed-off plan.
    private func snapshotHandoff(_ c: String) throws -> String {
        guard let p = plan(c) else { throw Failure.unavailable(c) }
        let id = UUID().uuidString
        try store.write(p, to: "handoffs/\(c)-\(id).json")
        return id
    }

    /// Copies the concept's current slides, in order, to `folder`, replacing any earlier export of this concept there.
    @discardableResult
    public func export(_ c: String, to folder: URL, source: String = "operator") throws -> [URL] {
        try operation.withLock {
            let slides = slideURLs(c)
            guard !slides.isEmpty else { throw Failure.nothingToExport }
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Named by neutral position, never by id: the file names must not reveal which option is the baseline.
            let prefix = "ak14-option\(concepts.position(of: c))-"
            for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(prefix) && old.hasSuffix(".png") {
                try fm.removeItem(at: folder.appending(path: old))
            }
            var out: [URL] = []
            for (i, url) in slides.enumerated() {
                let target = folder.appending(path: String(format: "%@%02d.png", prefix, i + 1))
                try fm.copyItem(at: url, to: target)
                out.append(target)
            }
            let snapshot = try snapshotHandoff(c)
            try record("carousel_exported", c, after: ["\(out.count) slides", "snapshot=\(snapshot)"], source: source)
            try? RunReport.rebuild(runDirectory: root)
            return out
        }
    }

    // MARK: - Internals

    /// Renders `plan` into a private staging directory, then swaps `edits/<concept>/` in with one rename
    /// and only then updates in-memory state. A failure leaves the previous edit (or original) untouched.
    private func commit(_ plan: CarouselPlan, _ c: String, seed: UInt64?) throws {
        guard let folder = sourceFolder else { throw Failure.noSource }
        let fm = FileManager.default
        let stagingRoot = root.appending(path: "edits/.staging/\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingRoot) }
        let result = try ConceptRendering.renderAll([plan], runID: runID, aspect: manifest.aspectRatio, photos: photos,
                                                    features: features, stylePack: stylePack, sourceFolder: folder,
                                                    into: stagingRoot, seedOverride: seed)
        guard !result.failed else { throw Failure.render(result.warnings) }
        let concept = stagingRoot.appending(path: "concept")
        try fm.createDirectory(at: concept, withIntermediateDirectories: true)
        try fm.moveItem(at: stagingRoot.appending(path: "slides/\(c)"), to: concept.appending(path: "slides"))
        try fm.moveItem(at: stagingRoot.appending(path: "layouts/\(c)"), to: concept.appending(path: "layouts"))
        try JSONCoding.encoder.encode(plan).write(to: concept.appending(path: "plan.json"))
        if let seed { try Data(String(seed, radix: 16).utf8).write(to: concept.appending(path: "seed.txt")) }

        let final = root.appending(path: "edits/\(c)")
        let backup = stagingRoot.appending(path: "previous")
        if fm.fileExists(atPath: final.path) { try fm.moveItem(at: final, to: backup) }
        do { try fm.moveItem(at: concept, to: final) } catch {
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: final) }
            throw error
        }
        state.withLock {
            working[c] = plan
            if let seed { seeds[c] = seed }
        }
    }

    /// The same local evidence the run composed from (triage flags stand in for the run-time safety flags).
    public func compositionContext() -> CompositionContext {
        let triage = Dictionary(uniqueKeysWithValues: concepts.triage.map { (AssetID(rawValue: $0.key), $0.value) })
        let spine = concepts.spine
        return CompositionContext(aspect: manifest.aspectRatio, photos: photos, features: features, triage: triage,
                                  flagged: Set(triage.filter { !$0.value.safety.isEmpty }.keys),
                                  sequenceIntent: Dictionary(zip(spine?.orderedAssetIDs ?? [], spine?.sequenceIntent ?? []),
                                                             uniquingKeysWith: { a, _ in a }),
                                  stylePack: stylePack, maxSlides: concepts.requestedSlides, storyHint: manifest.storyHint)
    }

    private func verify(_ id: AssetID, in folder: URL) throws {
        guard let p = photos[id] else { return }
        let url = folder.appending(path: p.sourceRelativePaths[0])
        guard let sha = try? Self.sha256(url), sha == p.contentSHA256 else { throw Failure.sourceChanged(p.sourceRelativePaths[0]) }
    }

    private func record(_ event: String, _ c: String?, slide: Int? = nil, assets: [AssetID]? = nil,
                        before: [String]? = nil, after: [String]? = nil, source: String = "operator") throws {
        try log.append(InteractionEvent(eventID: UUID().uuidString, runID: runID, timestamp: Date(), event: event,
                                        conceptID: c, slideIndex: slide, assetIDs: assets,
                                        before: before, after: after, source: source))
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
