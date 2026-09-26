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
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
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
    #expect(session.slideURLs(.plainDump).allSatisfy { $0.path.contains("/edits/plainDump/slides/") })

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
    #expect(Array(events.prefix(6)) == ["concepts_presented", "slide_reordered", "cover_changed", "photo_swapped", "cover_changed", "photo_removed"])
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


// MARK: - M5 review fixes

@Test func reportShowsStudioEditsAndEvents() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    try session.apply(.reorder(from: 0, to: 1), to: .designed)
    try session.select(.designed)
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("Studio edits") && html.contains("designed (edited)"))
    #expect(html.contains("edits/designed/slides/slide-01.png"))
    #expect(html.contains("slide_reordered") && html.contains("concept_selected"))
}

@Test func concurrentEditsAreSerializedAndLogConsistently() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let original = try #require(session.plan(.plainDump)).photoAssetIDs
    // Two "Move later" clicks on the first slide fired at once must both apply, in sequence.
    async let a: Void = Task.detached { try session.apply(.reorder(from: 0, to: 1), to: .plainDump) }.value
    async let b: Void = Task.detached { try session.reroll(.wildcard) }.value
    async let c: Void = Task.detached { try session.apply(.reorder(from: 1, to: 2), to: .plainDump) }.value
    _ = try await (a, b, c)
    let final = try #require(session.plan(.plainDump)).photoAssetIDs
    #expect(Set(final) == Set(original) && final != original)
    #expect(session.log.read().filter { $0.event == "slide_reordered" }.count == 2)
    #expect(session.slideURLs(.plainDump).count == original.count)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.url("edits/.staging").path)) ?? []
    #expect(leftovers.isEmpty)
}

@Test func failedRerollKeepsPreviousSlidesAndExportCleansOldFiles() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let exportDir = tmp.url.appending(path: "export")
    let first = try session.export(.designed, to: exportDir)
    // Remove a whole slide, export again into the same folder: no stale extra file survives.
    let plan = try #require(session.plan(.designed))
    let single = try #require(plan.slides.firstIndex { $0.photos.count == 1 && $0 != plan.slides[0] })
    try session.apply(.remove(slide: single, photo: plan.slides[single].photos[0].assetID), to: .designed)
    let second = try session.export(.designed, to: exportDir)
    #expect(second.count == first.count - 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: exportDir.path).filter { $0.hasPrefix("ak14-designed-") }.count == second.count)

    // A reroll whose render fails (source photo deleted) leaves the concept exactly as it was.
    let before = try session.slideURLs(.wildcard).map { try Data(contentsOf: $0) }
    let wildPlan = try #require(session.plan(.wildcard))
    let victim = try #require(session.photos[wildPlan.photoAssetIDs[0]]).sourceRelativePaths[0]
    try FileManager.default.removeItem(at: folder.appending(path: victim))
    #expect(throws: (any Error).self) { try session.reroll(.wildcard) }
    #expect(!session.isEdited(.wildcard))
    #expect(try session.slideURLs(.wildcard).map { try Data(contentsOf: $0) } == before)
    #expect(!session.log.read().contains { $0.event == "concept_rerolled" })
}

@Test func swapToAnUnverifiedChangedPhotoIsRefused() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let plan = try #require(session.plan(.designed))
    let old = plan.slides[0].photos[0].assetID
    let candidate = try #require(session.swapCandidates(.designed, photo: old).first)
    try FixtureFactory.writeScene(to: folder.appending(path: session.photos[candidate]!.sourceRelativePaths[0]), scene: 4242)
    #expect(throws: (any Error).self) { try session.apply(.swap(slide: 0, photo: old, with: candidate), to: .designed) }
    #expect(session.plan(.designed) == plan)
}
