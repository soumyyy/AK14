import Core
import Foundation
import ImageIO
import Render
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Session

private func candidateSceneFolder(_ tmp: TempDirectory, count: Int = 14) throws -> URL {
    let folder = try tmp.sub("trip")
    for i in 0..<count {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:05:29 %02d:%02d:00", 8 + i / 3, (i % 3) * 20)
        exif.orientation = i % 3 == 0 ? 6 : 1
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func candidateRun(_ tmp: TempDirectory, folder: URL, model: FakeModel) async throws -> RunStore {
    let options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                             cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    return try await RunPipeline.live(options: options, client: ResponsesClient(transport: model, sleep: { _ in }), log: { _ in }).run(options)
}

@Test func candidatesAreDistinctSafeAndStripsAreDeterministic() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try candidateSceneFolder(tmp)
    let store = try await candidateRun(tmp, folder: folder, model: FakeModel())
    let session = try RunSession(runDirectory: store.root)
    // Diversity remedies may drop a direction depending on the run's seed; use the first one that survived.
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    let id = try #require(report.plans.first { !$0.isBaseline }?.id)
    let plan = try #require(session.plan(id))
    let direction = try #require(plan.direction)
    let seed = try #require(plan.compositionSeed.flatMap { UInt64($0, radix: 16) })
    let layoutSeed = ComposerEngine.layoutSeed(runID: session.runID, id: id)
    let context = session.compositionContext()

    let storedReplay = ComposerEngine.compose(direction, id: id, context: context, seed: seed, layoutSeed: layoutSeed)
    #expect(storedReplay.plan == plan)

    let pool = ComposerEngine.candidates(direction, id: id, context: context, seed: seed, layoutSeed: layoutSeed)
    #expect((2...6).contains(pool.count))
    #expect(pool.indices.allSatisfy { i in pool.indices.allSatisfy { j in i == j || pool[i].plan != pool[j].plan } })
    #expect(pool.allSatisfy { $0.plan.compositionSeed == String(seed, radix: 16) })
    #expect(pool.allSatisfy { !$0.warnings.contains(where: { $0.contains("people are cropped") || $0.contains("could not fully satisfy") }) })
    let nearBest = pool.filter { $0.score <= pool[0].score + 0.04 }
    #expect(nearBest.contains(where: { $0.plan == storedReplay.plan }))

    let paths = try #require(report.renderedSlides[id])
    let slideURLs = paths.map { store.root.appending(path: $0) }
    let renderer = StripRenderer()
    let first = try renderer.strip(slides: slideURLs)
    let second = try renderer.strip(slides: slideURLs)
    #expect(first == second)
    let resolved = LayoutResolver.resolve(pool[0].plan, context: LayoutContext(aspect: context.aspect, photos: context.photos,
        features: context.features, stylePack: context.stylePack, seed: layoutSeed))
    #expect(try renderer.strip(resolved, photos: context.photos, sourceFolder: folder) ==
            renderer.strip(resolved, photos: context.photos, sourceFolder: folder))
    guard let source = CGImageSourceCreateWithData(first as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { Issue.record("strip JPEG could not be decoded"); return }
    let expected = slideURLs.reduce(0) { width, url in
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let slide = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return width }
        return width + Int((Double(slide.width) * 96 / Double(slide.height)).rounded()) + 4
    } - 4
    #expect(abs(image.width - expected) <= slideURLs.count)
    #expect(image.height == 96)
}
