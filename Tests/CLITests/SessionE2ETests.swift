import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Session

private func makeRun(_ tmp: TempDirectory) async throws -> (RunStore, URL) {
    let folder = try tmp.sub("trip")
    for i in 0..<12 {
        var exif = FixtureFactory.Exif(); exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"))
    let store = try await RunPipeline.live(options: o, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(o)
    return (store, folder)
}

private func bytes(_ urls: [URL]) throws -> [Data] { try urls.map { try Data(contentsOf: $0) } }

@Test func studioEditsRerenderLogAndExportWithoutTouchingOriginals() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    #expect(session.availableConcepts == [.plainDump, .designed, .wildcard])
    let originalPlans = try Data(contentsOf: store.url("plans/director.json"))
    let originalSlides = try bytes(session.slideURLs(.designed))

    // Editing before choosing a source folder is refused.
    #expect(throws: (any Error).self) { try session.reroll(.designed) }
    try session.setSource(folder)
    try session.presented()

    // Reorder Plain: order changes, still one photo per slide, re-rendered in edits/.
    let plain0 = try #require(session.plan(.plainDump))
    try session.apply(.reorder(from: 0, to: 2), to: .plainDump)
    let plain1 = try #require(session.plan(.plainDump))
    #expect(plain1.photoAssetIDs[2] == plain0.photoAssetIDs[0] && plain1.slides.allSatisfy { $0.photos.count == 1 })
    #expect(session.slideURLs(.plainDump).count == plain1.slides.count)
    #expect(session.slideURLs(.plainDump).allSatisfy { $0.path.contains("/edits/slides/plainDump/") })

    // Swap on Designed with a real candidate; candidates never include photos already used.
    let designed = try #require(session.plan(.designed))
    let target = designed.slides[0].photos[0].assetID
    let candidates = session.swapCandidates(.designed, photo: target)
    #expect(!candidates.isEmpty && Set(candidates).isDisjoint(with: designed.photoAssetIDs))
    try session.apply(.swap(slide: 0, photo: target, with: candidates[0]), to: .designed)
    #expect(session.plan(.designed)?.slides[0].photos[0].assetID == candidates[0])
    #expect(try bytes(session.slideURLs(.designed)) != originalSlides)

    // Remove the only photo of a slide → slide dropped (never padded).
    let before = try #require(session.plan(.designed)).slides.count
    let single = try #require(session.plan(.designed)?.slides.firstIndex { $0.photos.count == 1 && $0 != session.plan(.designed)!.slides[0] })
    try session.apply(.remove(slide: single, photo: session.plan(.designed)!.slides[single].photos[0].assetID), to: .designed)
    #expect(session.plan(.designed)?.slides.count == before - 1)
    #expect(session.slideURLs(.designed).count == before - 1)

    // Remove one photo from a two-photo slide → primitive downgraded, still renders.
    if let pair = session.plan(.designed)?.slides.firstIndex(where: { $0.photos.count == 2 }) {
        try session.apply(.remove(slide: pair, photo: session.plan(.designed)!.slides[pair].photos[1].assetID), to: .designed)
        #expect(session.plan(.designed)?.slides[pair].primitive == .hero)
    }

    // Reroll: new layout, same plan.
    let wildBefore = try bytes(session.slideURLs(.wildcard))
    let wildPlan = session.plan(.wildcard)
    try session.reroll(.wildcard)
    #expect(session.plan(.wildcard) == wildPlan)
    let wildAfter = try bytes(session.slideURLs(.wildcard))
    #expect(wildAfter != wildBefore)

    // Select + export ordered files.
    try session.select(.designed)
    let exported = try session.export(.designed, to: tmp.url.appending(path: "export"))
    #expect(exported.map(\.lastPathComponent) == (1...exported.count).map { String(format: "ak14-designed-%02d.png", $0) })
    #expect(try bytes(exported) == bytes(session.slideURLs(.designed)))

    // Originals untouched; events logged in order; a reopened session sees the edits.
    #expect(try Data(contentsOf: store.url("plans/director.json")) == originalPlans)
    #expect(try bytes(try RunSession(runDirectory: store.root).slideURLs(.designed)) == bytes(session.slideURLs(.designed)))
    let events = session.log.read().map(\.event)
    #expect(Array(events.prefix(4)) == ["concepts_presented", "slide_reordered", "photo_swapped", "photo_removed"])
    #expect(events.suffix(3) == ["concept_rerolled", "concept_selected", "carousel_exported"])
    #expect(session.log.read().allSatisfy { $0.runID == session.runID && $0.source == "operator" })
    let raw = try String(contentsOf: session.log.url, encoding: .utf8)
    #expect(!raw.contains("/Users/") && !raw.contains(tmp.url.path))
}

@Test func editsRejectInvalidOperationsAndChangedSources() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let plan = try #require(session.plan(.designed))
    #expect(throws: PlanEditError.alreadyInConcept(plan.photoAssetIDs[1])) {
        try session.apply(.swap(slide: 0, photo: plan.photoAssetIDs[0], with: plan.photoAssetIDs[1]), to: .designed)
    }
    #expect(throws: PlanEditError.slideOutOfRange(99)) { try session.apply(.reorder(from: 99, to: 0), to: .designed) }
    // A modified source photo is detected before anything renders.
    let first = try #require(session.photos[plan.photoAssetIDs[0]]?.sourceRelativePaths.first)
    try FixtureFactory.writeScene(to: folder.appending(path: first), scene: 999)
    #expect(throws: (any Error).self) { try RunSession(runDirectory: store.root).setSource(folder) }
}

@Test func runsWithoutConceptsCannotBeOpened() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("x")
    try FixtureFactory.writeScene(to: folder.appending(path: "a.jpg"), scene: 1)
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), noLLM: true)
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    #expect(throws: (any Error).self) { _ = try RunSession(runDirectory: store.root) }
}
