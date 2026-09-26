import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director

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
    #expect(m.versions["renderer"] == "render-1" && m.versions["resolver"] == "layout-2" && m.versions["composer"] == ComposerEngine.version)

    for plan in d.plans {
        let concept = plan.id
        let slides = try #require(d.renderedSlides[concept])
        #expect(slides.count == plan.slides.count, "\(concept) rendered \(slides.count)/\(plan.slides.count)")
        for (i, path) in slides.enumerated() {
            #expect(FileManager.default.fileExists(atPath: store.url(path).path))
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
    #expect(try digests() != before)
}

@Test func undatedPhotosOmitDateStampsGracefully() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await run(tmp, folder: try sceneFolder(tmp, dated: false))
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plans.allSatisfy { d.renderedSlides[$0.id]?.count == $0.slides.count })
}

// MARK: - M4 review fixes

@Test func stampsUseLocalCaptureDateAndFilmEdgeKeepsContentClear() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    // The composer decides decoration; force a film edge and a date stamp onto one slide so both paths are exercised.
    var d = try store.read(ConceptsReport.self, from: "plans/director.json")
    let i = try #require(d.plans.firstIndex { $0.id == "c1" })
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
    let i = try #require(d.plans.firstIndex { $0.id == "c1" })
    d.plans[i].slides[0].photos = [PhotoElement.plain(AssetID(rawValue: "a_doesnotexist"))]   // hand-edited plan
    try store.write(d, to: "plans/director.json")
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    let slide = try store.read(ResolvedSlide.self, from: "layouts/c1/slide-01.json")
    #expect(slide.elements.isEmpty && slide.warnings.contains { $0.contains("no usable photos") })
    #expect(!FileManager.default.fileExists(atPath: store.url(".rerender-backup").path))
    #expect(!FileManager.default.fileExists(atPath: store.url(".rerender").path))
}

// MARK: - Placement engine (layout-2)

@Test func composerKeepsHierarchyCropsAndRhythmPostable() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    var report: [String] = []
    for plan in d.plans where !plan.isBaseline {
        let concept = plan.id
        var families: [String] = []
        for i in plan.slides.indices {
            let s = try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", concept, i + 1))
            let m = try #require(s.metrics, "\(concept) slide \(i + 1) has no metrics")
            let variant = try #require(s.variant)
            report.append("\(concept) \(i + 1) \(variant) cov \(m.coverage) hero \(m.heroShare ?? 0) loss \(m.maxCropLoss)")
            if s.primitive == .asymmetricPair || s.primitive == .inset {
                #expect((m.heroShare ?? 0) >= 1.5, "\(concept) slide \(i + 1): hero only \(m.heroShare ?? 0)× the support")
            }
            if s.primitive == .overlapCluster { #expect((m.heroShare ?? 0) >= 1.0, "\(concept) slide \(i + 1): cluster hero smaller than a support") }
            if s.primitive != .fullBleed { #expect(m.maxCropLoss <= 0.5, "\(concept) slide \(i + 1) crops \(m.maxCropLoss) of a photo") }
            #expect(m.coverage >= 0.2, "\(concept) slide \(i + 1): photos cover only \(m.coverage) of the slide")
            families.append(variant.split(separator: ".").prefix(2).joined(separator: "."))
        }
        let repeats = zip(families, families.dropFirst()).filter { $0 == $1 && $0 != "bleed" }.count
        #expect(repeats <= 1, "\(concept) repeats an arrangement on consecutive slides \(repeats)×: \(families)")
    }
    print(report.joined(separator: "\n"))
}
