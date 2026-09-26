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
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"))
    return try await RunPipeline.live(options: o, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(o)
}

@Test func everyConceptRendersWithSafeGeometryAndRerendersIdentically() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    let m = try store.read(RunManifest.self, from: "manifest.json")
    let features = Dictionary(uniqueKeysWithValues: try store.read([PhotoFeatures].self, from: "cache/features.json").map { ($0.assetID, $0) })
    #expect(m.versions["renderer"] == "render-1" && m.versions["resolver"] == "layout-1")

    for plan in d.plans {
        let concept = plan.conceptType.rawValue
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
    #expect(d.renderedSlides["designed"]?.isEmpty == false && d.renderedSlides["wildcard"]?.isEmpty == false)
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("slides/designed/slide-01.png") && html.contains("slides/wildcard/slide-01.png"))

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
    #expect(d.plans.allSatisfy { d.renderedSlides[$0.conceptType.rawValue]?.count == $0.slides.count })
}
