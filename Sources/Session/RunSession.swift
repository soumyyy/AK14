import CryptoKit
import Core
import Foundation
import Render

/// Everything Studio does to a run: load it, apply the allowed edits, re-render, export, and log behaviour.
/// Edits live in `edits/`; the run's original `plans/` and `slides/` are never modified.
public final class RunSession: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case noConcepts, noSource, sourceChanged(String), unavailable(String), render([String])
        public var description: String {
            switch self {
            case .noConcepts: "this run has no concepts (it was made with --no-llm or the model was skipped)"
            case .noSource: "choose the run's source photo folder first"
            case .sourceChanged(let p): "source photo changed or is missing: \(p)"
            case .unavailable(let c): "\(c) is not available in this run"
            case .render(let f): "render failed: \(f.prefix(3).joined(separator: "; "))"
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
    public private(set) var sourceFolder: URL?
    private var working: [ConceptType: CarouselPlan] = [:]
    private var seeds: [String: String] = [:]
    private let lock = NSLock()
    private let store: RunStore

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
        for type in ConceptType.allCases {
            if let p = try? store.read(CarouselPlan.self, from: "edits/\(type.rawValue)/plan.json") { working[type] = p }
        }
        seeds = (try? store.read([String: String].self, from: "edits/seeds.json")) ?? [:]
    }

    public var runID: String { manifest.runID }
    public var availableConcepts: [ConceptType] { concepts.plans.map(\.conceptType) }

    /// Verifies every photo used by any concept (or the candidate pool) against its recorded content hash.
    public func setSource(_ folder: URL) throws {
        let folder = folder.resolvingSymlinksInPath()
        let ids = Set(concepts.plans.flatMap(\.photoAssetIDs) + concepts.pool)
        for id in ids {
            guard let p = photos[id] else { continue }
            let url = folder.appending(path: p.sourceRelativePaths[0])
            guard let sha = try? Self.sha256(url), sha == p.contentSHA256 else { throw Failure.sourceChanged(p.sourceRelativePaths[0]) }
        }
        lock.withLock { sourceFolder = folder }
    }

    // MARK: - Reading

    public func plan(_ c: ConceptType) -> CarouselPlan? {
        lock.withLock { working[c] } ?? concepts.plans.first { $0.conceptType == c }
    }

    public func isEdited(_ c: ConceptType) -> Bool { lock.withLock { working[c] != nil || seeds[c.rawValue] != nil } }

    /// Current slide images: edited output when present, else the run's original render.
    public func slideURLs(_ c: ConceptType) -> [URL] {
        if isEdited(c) {
            let dir = root.appending(path: "edits/slides/\(c.rawValue)")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()) ?? []
            return names.map { dir.appending(path: $0) }
        }
        return (concepts.renderedSlides[c.rawValue] ?? []).map { root.appending(path: $0) }
    }

    public func thumbnailURL(_ id: AssetID) -> URL { root.appending(path: "cache/thumbnails/analysis/\(id.rawValue).jpg") }

    /// Swap candidates: the photo's own shot-cluster alternates first, then the planning pool,
    /// excluding photos already in the concept.
    public func swapCandidates(_ c: ConceptType, photo: AssetID) -> [AssetID] {
        let used = Set(plan(c)?.photoAssetIDs ?? [])
        let cluster = reduction?.clusters.first { $0.memberAssetIDs.contains(photo) }?.memberAssetIDs ?? []
        let rejected = Set(reduction?.junk.filter { $0.verdict == .reject }.map(\.assetID) ?? [])
        var seen = Set<AssetID>(), out: [AssetID] = []
        for id in cluster + concepts.pool where !used.contains(id) && !rejected.contains(id) && photos[id] != nil {
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    // MARK: - Edits

    public func apply(_ edit: PlanEdit, to c: ConceptType, source: String = "operator") throws {
        guard let current = plan(c) else { throw Failure.unavailable(c.rawValue) }
        var edited = try PlanEditor.apply(edit, to: current)
        if c == .plainDump {
            edited.slides = edited.slides.map { var s = $0; s.decorations = []; s.stamps = []; return s }
        }
        try render(edited, c)
        lock.withLock { working[c] = edited }
        try store.write(edited, to: "edits/\(c.rawValue)/plan.json")
        switch edit {
        case .reorder(let from, let to):
            try record("slide_reordered", c, slide: to, before: current.slides.map { $0.photos.map(\.assetID.rawValue).joined(separator: "+") },
                       after: edited.slides.map { $0.photos.map(\.assetID.rawValue).joined(separator: "+") }, source: source)
            _ = from  // the before/after orders carry the move
        case .swap(let s, let old, let new):
            try record("photo_swapped", c, slide: s, assets: [old, new], before: [old.rawValue], after: [new.rawValue], source: source)
        case .remove(let s, let id):
            try record("photo_removed", c, slide: s, assets: [id], before: [id.rawValue], after: [], source: source)
        }
    }

    /// New layout seed for the concept (no model call).
    public func reroll(_ c: ConceptType, source: String = "operator") throws {
        guard let current = plan(c) else { throw Failure.unavailable(c.rawValue) }
        let seed = SeededRandom.seed(runID, c.rawValue, UUID().uuidString)
        lock.withLock { seeds[c.rawValue] = String(seed, radix: 16) }
        try render(current, c)
        try store.write(lock.withLock { seeds }, to: "edits/seeds.json")
        try record("concept_rerolled", c, source: source)
    }

    public func select(_ c: ConceptType, source: String = "operator") throws { try record("concept_selected", c, source: source) }
    public func presented(source: String = "operator") throws { try record("concepts_presented", nil, source: source) }
    public func shared(_ c: ConceptType, service: String, source: String = "operator") throws {
        try record("carousel_shared", c, after: [service], source: source)
    }

    /// Copies the concept's current slides, in order, to `folder`. Returns the written files.
    @discardableResult
    public func export(_ c: ConceptType, to folder: URL, source: String = "operator") throws -> [URL] {
        let slides = slideURLs(c)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [URL] = []
        for (i, url) in slides.enumerated() {
            let target = folder.appending(path: String(format: "ak14-%@-%02d.png", c.rawValue, i + 1))
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            out.append(target)
        }
        try record("carousel_exported", c, after: ["\(out.count) slides"], source: source)
        return out
    }

    // MARK: - Internals

    private func render(_ plan: CarouselPlan, _ c: ConceptType) throws {
        guard let folder = lock.withLock({ sourceFolder }) else { throw Failure.noSource }
        let editsRoot = root.appending(path: "edits")
        let staging = root.appending(path: ".edits-render")
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        let seed = lock.withLock { seeds[c.rawValue] }.flatMap { UInt64($0, radix: 16) }
        let result = try ConceptRendering.renderAll([plan], runID: runID, aspect: manifest.aspectRatio, photos: photos,
                                                    features: features, stylePack: stylePack, sourceFolder: folder,
                                                    into: staging, seedOverride: seed)
        guard !result.failed else { try? fm.removeItem(at: staging); throw Failure.render(result.warnings) }
        for dir in ["slides", "layouts"] {
            let final = editsRoot.appending(path: "\(dir)/\(c.rawValue)")
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: staging.appending(path: "\(dir)/\(c.rawValue)"), to: final)
        }
        try? fm.removeItem(at: staging)
    }

    private func record(_ event: String, _ c: ConceptType?, slide: Int? = nil, assets: [AssetID]? = nil,
                        before: [String]? = nil, after: [String]? = nil, source: String = "operator") throws {
        try log.append(InteractionEvent(eventID: UUID().uuidString, runID: runID, timestamp: Date(), event: event,
                                        conceptID: c?.rawValue, slideIndex: slide, assetIDs: assets,
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
