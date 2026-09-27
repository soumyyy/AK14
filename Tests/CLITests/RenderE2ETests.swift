import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Analysis
@testable import Core
@testable import Director
@testable import Render

private func sceneFolder(_ tmp: TempDirectory, count: Int = 12, dated: Bool = true) throws -> URL {
    let folder = try tmp.sub("trip")
    for i in 0..<count {
        var exif = FixtureFactory.Exif()
        exif.date = dated ? String(format: "2026:05:29 %02d:10:00", 8 + i) : nil
        exif.orientation = i % 3 == 0 ? 6 : 1                       // mix portrait and landscape sources
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func run(_ tmp: TempDirectory, folder: URL) async throws -> RunStore {
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    return try await RunPipeline.live(options: o, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(o)
}

@Test func everyConceptRendersWithSafeGeometryAndRerendersIdentically() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    let m = try store.read(RunManifest.self, from: "manifest.json")
    let features = Dictionary(uniqueKeysWithValues: try store.read([PhotoFeatures].self, from: "cache/features.json").map { ($0.assetID, $0) })
    #expect(m.versions["renderer"] == "render-2" && m.versions["resolver"] == "layout-3" && m.versions["composer"] == ComposerEngine.version)

    let fm = FileManager.default
    for plan in d.plans {
        let concept = plan.id
        let slides = try #require(d.renderedSlides[concept])
        #expect(slides.count == plan.slides.count, "\(concept) rendered \(slides.count)/\(plan.slides.count)")
        // A recipe-filled concept (spec §3) renders from `documents/<id>.json`, not `layouts/<id>/slide-NN.json`;
        // check the same off-canvas/bounds safety property against its CanvasDocument layers instead.
        if fm.fileExists(atPath: store.url("documents/\(concept).json").path) {
            let document = try store.read(CanvasDocument.self, from: "documents/\(concept).json")
            for i in 0..<max(1, plan.slides.count) {
                for layer in document.layers(onSlide: i) {
                    let localX = (layer.frame.x - Double(i) / Double(document.slideCount)) * Double(document.slideCount)
                    #expect(localX >= -0.001 && layer.frame.y >= -0.05 && localX + layer.frame.width * Double(document.slideCount) <= 1.001
                            && layer.frame.y + layer.frame.height <= 1.001,
                            "\(concept) slide \(i + 1) \(layer.kind) out of bounds: \(layer.frame)")
                }
            }
            continue
        }
        for (i, path) in slides.enumerated() {
            #expect(fm.fileExists(atPath: store.url(path).path))
            let layout = try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", concept, i + 1))
            for e in layout.elements where !(e.kind == .photo && layout.background == "none" && e.zIndex == 0) {
                let f = e.frame
                #expect(f.x >= -0.001 && f.y >= -0.05 && f.x + f.width <= 1.001 && f.y + f.height <= 1.001,
                        "\(concept) slide \(i + 1) \(e.kind) out of bounds: \(f)")
            }
            if layout.primitive == .overlapCluster || layout.primitive == .inset || layout.primitive == .asymmetricPair {
                let penalty = LayoutResolver.overlapPenalty(layout.elements.filter { $0.kind == .photo },
                                                            canvasW: Double(m.aspectRatio.exportWidth), canvasH: Double(m.aspectRatio.exportHeight),
                                                            features: features, minVisible: 0.55)
                #expect(penalty == 0 || layout.warnings.contains { $0.contains("could not") || $0.contains("face") },
                        "\(concept) slide \(i + 1) violates visibility/face constraints silently")
            }
        }
    }
    #expect(d.renderedSlides["c1"]?.isEmpty == false && d.renderedSlides["c2"]?.isEmpty == false)
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("slides/c1/slide-01.png") && html.contains("slides/c2/slide-01.png"))

    // Rerender: no model calls, every PNG byte-identical; a different seed changes designed layouts.
    func digests() throws -> [String: Data] {
        var out: [String: Data] = [:]
        for (c, paths) in d.renderedSlides { for p in paths { out[c + p] = try Data(contentsOf: store.url(p)) } }
        return out
    }
    let before = try digests()
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    #expect(try digests() == before)
    try RerenderCommand.rerender(runDirectory: store.root, source: folder, seed: 0xABCDEF)
    // Clean output is one consistent card per photo, so a new seed may legitimately change nothing.
    if !ComposerEngine.cleanOutput { #expect(try digests() != before) }
}

@Test func undatedPhotosOmitDateStampsGracefully() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await run(tmp, folder: try sceneFolder(tmp, dated: false))
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plans.allSatisfy { d.renderedSlides[$0.id]?.count == $0.slides.count })
}

@Test func fourByThreeLandscapeKeepsTheFullBleedRetentionFloor() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp, count: 6)
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    let landscape = try #require(records.first { $0.pixelWidth > $0.pixelHeight })
    let features = PhotoFeatures(assetID: landscape.assetID, analyzerVersion: "test")
    let style = StyleVector(density: "balanced", overlap: "none", grouping: "single", decoration: "none", rotation: "none", whitespace: "airy")
    let direction = Direction(brief: "", style: style, coverAssetID: landscape.assetID, orderedAssetIDs: [landscape.assetID])
    let slide = SlidePlan(primitive: .fullBleed, mood: "", density: "balanced", photos: [.plain(landscape.assetID)], decorations: [], stamps: [])
    let plan = CarouselPlan(id: "c1", brief: "", direction: direction, slides: Array(repeating: slide, count: 12))
    let context = LayoutContext(aspect: .portrait4x5, photos: [landscape.assetID: landscape], features: [landscape.assetID: features],
                                stylePack: try StylePackLoader.load(), seed: 92814)
    let first = LayoutResolver.resolve(plan, context: context)
    let repeated = LayoutResolver.resolve(plan, context: context)
    #expect(first == repeated, "same layout seed must reproduce every slide")
    let lead = try #require(first.slides.first)
    #expect(lead.primitive == .fullBleed && lead.requestedPrimitive == .fullBleed)
    #expect(!lead.warnings.contains { $0.contains("landscape crop is too severe") })
    #expect((lead.metrics?.maxCropLoss ?? 1) <= 0.42, "a 4:3 landscape retains at least 58% of its source crop")
    let positions = Set(first.slides.compactMap { $0.variant }.filter { $0.contains("whole.") || $0.hasPrefix("band.") })
    // Clean output uses one consistent white-border card on purpose; variety applies to the designed mode.
    if !ComposerEngine.cleanOutput { #expect(positions.count > 1, "landscape single-photo layouts should vary: \(positions)") }
}

@Test func singleHeroCardsUsePhotoWashOnlyWhenTheyLeaveSubstantialCanvas() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp, count: 6)
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    let landscape = try #require(records.first { $0.pixelWidth > $0.pixelHeight })
    let style = StyleVector(density: "balanced", overlap: "none", grouping: "single", decoration: "none", rotation: "none", whitespace: "standard")
    let direction = Direction(brief: "", style: style, coverAssetID: landscape.assetID, orderedAssetIDs: [landscape.assetID])
    let photos = [PhotoElement.plain(landscape.assetID)]
    let hero = SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: photos, decorations: [], stamps: [])
    let framed = SlidePlan(primitive: .framedHero, mood: "", density: "balanced", photos: photos, decorations: [], stamps: [])
    let quiet = SlidePlan(primitive: .hero, mood: "", density: "quiet", photos: photos, decorations: [], stamps: [])
    let plan = CarouselPlan(id: "single-cards", brief: "", direction: direction,
                            slides: [hero, framed, hero, framed, hero, quiet])
    let context = LayoutContext(aspect: .portrait4x5, photos: [landscape.assetID: landscape],
                                features: [landscape.assetID: PhotoFeatures(assetID: landscape.assetID, analyzerVersion: "test")],
                                stylePack: try StylePackLoader.load(), seed: 92814)
    let resolved = LayoutResolver.resolve(plan, context: context)
    #expect(resolved == LayoutResolver.resolve(plan, context: context), "background choice must be deterministic")
    // Owner decision (2026-09-27): no photo-derived blurred washes behind a photo; they read as filler.
    for slide in resolved.slides {
        #expect(!slide.background.hasPrefix("wash:"), "slide \(slide.index + 1) uses a blurred photo wash")
    }
}

@Test func landscapeHeavyRunUsesSafeBandsAndStackedPairsDeterministically() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    #expect(Double(records.filter { $0.orientation == .landscape }.count) / Double(records.count) >= 0.6)
    #expect(CarouselAspect.infer(from: records) != .portrait3x4, "landscape-heavy sets never use the tallest canvas")

    let store = try await run(tmp, folder: folder)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.aspectRatio != .portrait3x4)
    var sawBand = false, sawPair = false
    for plan in d.plans {
        // A recipe-filled concept has no ResolvedSlide layouts (spec §3): its bands/pairs are governed by the
        // recipe's own slot rules and covered separately, so this legacy-primitive rhythm check skips it.
        guard FileManager.default.fileExists(atPath: store.url("layouts/\(plan.id)").path) else { continue }
        for i in plan.slides.indices {
            let slide = try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", plan.id, i + 1))
            guard let variant = slide.variant, variant.hasPrefix("band.") || variant.hasPrefix("bandpair.") else { continue }
            sawBand = sawBand || variant.hasPrefix("band.")
            sawPair = sawPair || variant.hasPrefix("bandpair.")
            #expect(!slide.background.hasPrefix("wash:"), "no blurred photo washes (owner decision)")
            #expect((slide.metrics?.maxCropLoss ?? 1) <= 0.2, "\(variant) crop loss exceeds 20%")
            #expect(!slide.warnings.contains { $0.contains("some people are cropped") }, "\(variant) cuts people")
        }
    }
    // Bands compete on the same scoring as every other arrangement; on a landscape-heavy set at least one should win.
    if !ComposerEngine.cleanOutput { #expect(sawBand || sawPair, "landscape-heavy fixture never chose a band arrangement") }
    func renderedBytes() throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for (id, paths) in d.renderedSlides {
            for path in paths { bytes[id + path] = try Data(contentsOf: store.url(path)) }
        }
        return bytes
    }
    let before = try renderedBytes()
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    #expect(try renderedBytes() == before)
}

// MARK: - M4 review fixes

@Test func stampsUseLocalCaptureDateAndFilmEdgeKeepsContentClear() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    // The composer decides decoration; force a film edge and a date stamp onto one slide so both paths are exercised.
    var d = try store.read(ConceptsReport.self, from: "plans/director.json")
    // Every non-baseline direction may score high enough to earn a recipe (spec §3/§4) and render as a
    // CanvasDocument instead, which has no `decorations`/`stamps` to hand-edit; the baseline never does
    // (RecipeFiller.select always returns nil for it), so it is the one concept guaranteed to stay on the
    // legacy primitive/decoration path this test exercises.
    let i = try #require(d.plans.firstIndex { $0.isBaseline })
    d.plans[i].slides[0].decorations = [DecorationElement(decorationID: "film-edge", intensity: "medium")]
    d.plans[i].slides[0].stamps = [StampElement(kind: "date", placement: "bottomRight")]
    try store.write(d, to: "plans/director.json")
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    let band = StyleMetrics.filmBand(canvasWidth: Double(m.aspectRatio.exportWidth)) / Double(m.aspectRatio.exportWidth)
    let layouts = try FileManager.default.subpathsOfDirectory(atPath: store.url("layouts").path).filter { $0.hasSuffix(".json") }
    var sawFilm = false, sawStamp = false
    for path in layouts {
        let slide = try store.read(ResolvedSlide.self, from: "layouts/" + path)
        for e in slide.elements where e.kind == .stamp {
            sawStamp = true
            #expect(e.text == "26 5 29", "stamp text \(e.text ?? "nil")")   // fixture EXIF local date 2026:05:29, no apostrophe glyph
        }
        guard slide.filmEdge else { continue }
        sawFilm = true
        for e in slide.elements where e.kind != .tape {
            #expect(e.frame.x >= band - 0.001 && e.frame.x + e.frame.width <= 1 - band + 0.001,
                    "\(path) \(e.kind) under the film band: \(e.frame)")
        }
    }
    #expect(sawFilm && sawStamp)
}

@Test func slideWithNoUsablePhotosRendersEmptyInsteadOfCrashing() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    var d = try store.read(ConceptsReport.self, from: "plans/director.json")
    // The baseline is the one concept guaranteed to stay on the legacy ResolvedSlide path (see the comment in
    // stampsUseLocalCaptureDateAndFilmEdgeKeepsContentClear): any direction may earn a recipe (spec §3/§4)
    // and render as a CanvasDocument instead, which never writes `layouts/<id>`.
    let i = try #require(d.plans.firstIndex { $0.isBaseline })
    d.plans[i].slides[0].photos = [PhotoElement.plain(AssetID(rawValue: "a_doesnotexist"))]   // hand-edited plan
    try store.write(d, to: "plans/director.json")
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    let slide = try store.read(ResolvedSlide.self, from: "layouts/\(d.plans[i].id)/slide-01.json")
    #expect(slide.elements.isEmpty && slide.warnings.contains { $0.contains("no usable photos") })
    #expect(!FileManager.default.fileExists(atPath: store.url(".rerender-backup").path))
    #expect(!FileManager.default.fileExists(atPath: store.url(".rerender").path))
}

// MARK: - Placement engine (layout-3)

@Test func composerKeepsHierarchyCropsAndRhythmPostable() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    var report: [String] = []
    for plan in d.plans where !plan.isBaseline {
        let concept = plan.id
        // Recipe-filled concepts (spec §3) place photos through the recipe's slot rules, not the primitive/
        // hierarchy scoring below; their look is judged instead by the visual sample-and-review pass.
        guard FileManager.default.fileExists(atPath: store.url("layouts/\(concept)").path) else { continue }
        var families: [String] = []
        var singlePhotoVariants: Set<String> = []
        for i in plan.slides.indices {
            let s = try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", concept, i + 1))
            let m = try #require(s.metrics, "\(concept) slide \(i + 1) has no metrics")
            let variant = try #require(s.variant)
            if s.primitive == .hero || s.primitive == .framedHero { singlePhotoVariants.insert(variant) }
            report.append("\(concept) \(i + 1) \(variant) cov \(m.coverage) hero \(m.heroShare ?? 0) loss \(m.maxCropLoss)")
            // Imported template pages author their own hierarchy (balanced pairs are intended).
            let templated = variant.hasPrefix("template.")
            if !templated && (s.primitive == .asymmetricPair || s.primitive == .inset) {
                #expect((m.heroShare ?? 0) >= 1.5, "\(concept) slide \(i + 1): hero only \(m.heroShare ?? 0)× the support")
            }
            if !templated && s.primitive == .overlapCluster { #expect((m.heroShare ?? 0) >= 1.0, "\(concept) slide \(i + 1): cluster hero smaller than a support") }
            if s.primitive != .fullBleed { #expect(m.maxCropLoss <= 0.5, "\(concept) slide \(i + 1) crops \(m.maxCropLoss) of a photo") }
            #expect(m.coverage >= 0.2, "\(concept) slide \(i + 1): photos cover only \(m.coverage) of the slide")
            families.append(variant.split(separator: ".").prefix(2).joined(separator: "."))
        }
        let repeats = zip(families, families.dropFirst()).filter { $0 == $1 && $0 != "bleed" }.count
        if !ComposerEngine.cleanOutput {
            #expect(repeats <= 1, "\(concept) repeats an arrangement on consecutive slides \(repeats)×: \(families)")
        }
        if plan.style?.whitespace == "airy" {
            #expect(singlePhotoVariants.count > 1, "\(concept) airy single-photo layouts never vary: \(singlePhotoVariants)")
        }
    }
    print(report.joined(separator: "\n"))
}
