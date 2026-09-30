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
    #expect(Set(session.availableConcepts) == ["baseline", "c1", "c2", "c3"])
    let originalPlans = try Data(contentsOf: store.url("plans/director.json"))
    let originalSlides = try bytes(session.slideURLs("c1"))

    // Editing before choosing a source folder is refused.
    #expect(throws: (any Error).self) { try session.reroll("c1") }
    try session.setSource(folder)
    try session.presented()

    // Reorder Plain: order changes, still one photo per slide, re-rendered in edits/.
    let plain0 = try #require(session.plan("baseline"))
    try session.apply(.reorder(from: 0, to: 2), to: "baseline")
    let plain1 = try #require(session.plan("baseline"))
    #expect(plain1.photoAssetIDs[2] == plain0.photoAssetIDs[0] && plain1.slides.allSatisfy { $0.photos.count == 1 })
    #expect(session.slideURLs("baseline").count == plain1.slides.count)
    #expect(session.slideURLs("baseline").allSatisfy { $0.path.contains("/edits/baseline/slides/") })

    // Swap on Designed with a real candidate; candidates never include photos already used.
    let designed = try #require(session.plan("c1"))
    let target = designed.slides[0].photos[0].assetID
    let candidates = session.swapCandidates("c1", photo: target)
    #expect(!candidates.isEmpty && Set(candidates).isDisjoint(with: designed.photoAssetIDs))
    try session.apply(.swap(slide: 0, photo: target, with: candidates[0]), to: "c1")
    #expect(session.plan("c1")?.slides[0].photos[0].assetID == candidates[0])
    #expect(try bytes(session.slideURLs("c1")) != originalSlides)

    // Remove the only photo of a slide → slide dropped (never padded).
    let before = try #require(session.plan("c1")).slides.count
    let single = try #require(session.plan("c1")?.slides.firstIndex { $0.photos.count == 1 && $0 != session.plan("c1")!.slides[0] })
    try session.apply(.remove(slide: single, photo: session.plan("c1")!.slides[single].photos[0].assetID), to: "c1")
    #expect(session.plan("c1")?.slides.count == before - 1)
    #expect(session.slideURLs("c1").count == before - 1)

    // Remove one photo from a two-photo slide → primitive downgraded, still renders.
    if let pair = session.plan("c1")?.slides.firstIndex(where: { $0.photos.count == 2 }) {
        try session.apply(.remove(slide: pair, photo: session.plan("c1")!.slides[pair].photos[1].assetID), to: "c1")
        #expect(session.plan("c1")?.slides[pair].primitive == .hero)
    }

    // Reroll: recomposed without a model call; the clean-output policy can render the same pixels
    // when it has no alternate safe placement, but the seed and plan are still recorded.
    let wildPlan = try #require(session.plan("c2"))
    try session.reroll("c2")
    let rerolled = try #require(session.plan("c2"))
    #expect(Set(rerolled.photoAssetIDs) == Set(wildPlan.photoAssetIDs) && rerolled.coverAssetID == wildPlan.coverAssetID)
    #expect(rerolled.style == wildPlan.style)
    let wildAfter = try bytes(session.slideURLs("c2"))
    #expect(rerolled.compositionSeed != wildPlan.compositionSeed)
    #expect(!wildAfter.isEmpty && wildAfter.allSatisfy { !$0.isEmpty })

    // Select + export ordered files.
    try session.select("c1")
    let exported = try session.export("c1", to: tmp.url.appending(path: "export"))
    #expect(exported.map(\.lastPathComponent) == (1...exported.count).map { String(format: "ak14-option%d-%02d.png", session.concepts.position(of: "c1"), $0) })
    #expect(try bytes(exported) == bytes(session.slideURLs("c1")))

    // Originals untouched; events logged in order; a reopened session sees the edits.
    #expect(try Data(contentsOf: store.url("plans/director.json")) == originalPlans)
    #expect(try bytes(try RunSession(runDirectory: store.root).slideURLs("c1")) == bytes(session.slideURLs("c1")))
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
    let plan = try #require(session.plan("c1"))
    #expect(throws: PlanEditError.alreadyInConcept(plan.photoAssetIDs[1])) {
        try session.apply(.swap(slide: 0, photo: plan.photoAssetIDs[0], with: plan.photoAssetIDs[1]), to: "c1")
    }
    #expect(throws: PlanEditError.slideOutOfRange(99)) { try session.apply(.reorder(from: 99, to: 0), to: "c1") }
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
    try session.apply(.reorder(from: 0, to: 1), to: "c1")
    try session.select("c1")
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("Studio edits") && html.contains("c1 (edited)"))
    #expect(html.contains("edits/c1/slides/slide-01.png"))
    #expect(html.contains("slide_reordered") && html.contains("concept_selected"))
}

@Test func concurrentEditsAreSerializedAndLogConsistently() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let original = try #require(session.plan("baseline")).photoAssetIDs
    // Two "Move later" clicks on the first slide fired at once must both apply, in sequence.
    async let a: Void = Task.detached { try session.apply(.reorder(from: 0, to: 1), to: "baseline") }.value
    async let b: Void = Task.detached { try session.reroll("c2") }.value
    async let c: Void = Task.detached { try session.apply(.reorder(from: 1, to: 2), to: "baseline") }.value
    _ = try await (a, b, c)
    let final = try #require(session.plan("baseline")).photoAssetIDs
    #expect(Set(final) == Set(original) && final != original)
    #expect(session.log.read().filter { $0.event == "slide_reordered" }.count == 2)
    #expect(session.slideURLs("baseline").count == original.count)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.url("edits/.staging").path)) ?? []
    #expect(leftovers.isEmpty)
}

@Test func failedRerollKeepsPreviousSlidesAndExportCleansOldFiles() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let exportDir = tmp.url.appending(path: "export")
    let first = try session.export("c1", to: exportDir)
    // Remove a whole slide, export again into the same folder: no stale extra file survives.
    let plan = try #require(session.plan("c1"))
    let single = try #require(plan.slides.firstIndex { $0.photos.count == 1 && $0 != plan.slides[0] })
    try session.apply(.remove(slide: single, photo: plan.slides[single].photos[0].assetID), to: "c1")
    let second = try session.export("c1", to: exportDir)
    #expect(second.count == first.count - 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: exportDir.path).filter { $0.hasPrefix("ak14-option\(session.concepts.position(of: "c1"))-") }.count == second.count)

    // A reroll whose render fails (source photo deleted) leaves the concept exactly as it was.
    let before = try session.slideURLs("c2").map { try Data(contentsOf: $0) }
    let wildPlan = try #require(session.plan("c2"))
    let victim = try #require(session.photos[wildPlan.photoAssetIDs[0]]).sourceRelativePaths[0]
    try FileManager.default.removeItem(at: folder.appending(path: victim))
    #expect(throws: (any Error).self) { try session.reroll("c2") }
    #expect(!session.isEdited("c2"))
    #expect(try session.slideURLs("c2").map { try Data(contentsOf: $0) } == before)
    #expect(!session.log.read().contains { $0.event == "concept_rerolled" })
}

@Test func swapToAnUnverifiedChangedPhotoIsRefused() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (store, folder) = try await makeRun(tmp)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let plan = try #require(session.plan("c1"))
    let old = plan.slides[0].photos[0].assetID
    let candidate = try #require(session.swapCandidates("c1", photo: old).first)
    try FixtureFactory.writeScene(to: folder.appending(path: session.photos[candidate]!.sourceRelativePaths[0]), scene: 4242)
    #expect(throws: (any Error).self) { try session.apply(.swap(slide: 0, photo: old, with: candidate), to: "c1") }
    #expect(session.plan("c1") == plan)
}

struct SessionE2ETests {
    @Test(arguments: [(false, false), (true, false), (true, true)])
    func authoredRerollRetainsEditsAndRebuildsMoments(exactSet: Bool, keepOrder: Bool) async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let (store, folder, ids) = try await authoredRun(tmp, exactSet: exactSet, keepOrder: keepOrder)
        let session = try RunSession(runDirectory: store.root)
        try session.setSource(folder)
        let original = try #require(session.plan("c1"))
        let pages = session.compositionContext().pages
        func families(_ plan: CarouselPlan) -> Set<String> {
            Set(plan.slides.compactMap(\.placement?.pageID).compactMap { id in
                pages.first { $0.id == id }?.familyID
            }).subtracting(["layouts", "white-card"])
        }
        #expect(families(original).count == 1)
        // Reserve the removed photo as the sibling cover, so search has a distinct opening in every mode.
        try session.apply(.reorder(from: 3, to: 0), to: "baseline")
        let removeSlide = try #require(original.slides.firstIndex { $0.photos.contains { $0.assetID == ids[3] } })
        try session.apply(.remove(slide: removeSlide, photo: ids[3]), to: "c1")
        let afterRemove = try #require(session.plan("c1"))
        let grouped = try #require(afterRemove.slides.firstIndex { $0.photos.count > 1 && $0.placement?.runLength == 1 })
        let old = try #require(afterRemove.slides[grouped].photos.last?.assetID)
        let companions = afterRemove.slides[grouped].photos.map(\.assetID).filter { $0 != old }
        // Authored pages may borrow a neighbour; a swap joins its surviving slide companions.
        let companionMoment = try #require(original.direction?.moments.first { $0.photos.contains(where: companions.contains) })
        try session.apply(.swap(slide: grouped, photo: old, with: ids[8]), to: "c1")
        // A swapped-in cover shares no slide with an existing moment, so it needs a new opening moment.
        let beforeSingleSwap = try #require(session.plan("c1"))
        let cover = try #require(beforeSingleSwap.coverAssetID)
        #expect(beforeSingleSwap.slides[0].photos.map(\.assetID) == [cover])
        try session.apply(.swap(slide: 0, photo: cover, with: ids[9]), to: "c1")
        let edited = try #require(session.plan("c1"))
        try session.reroll("c1")
        let rerolled = try #require(session.plan("c1"))
        #expect(Set(rerolled.photoAssetIDs) == Set(edited.photoAssetIDs))
        #expect(!rerolled.photoAssetIDs.contains(ids[3]) && !rerolled.photoAssetIDs.contains(old))
        #expect(rerolled.photoAssetIDs.contains(ids[8]) && rerolled.photoAssetIDs.contains(ids[9]))
        #expect(rerolled.slides.allSatisfy { $0.placement != nil })
        #expect(families(rerolled) == families(original))
        if keepOrder { #expect(rerolled.photoAssetIDs == edited.photoAssetIDs) }
        let direction = try #require(rerolled.direction)
        #expect(Set(direction.orderedAssetIDs) == Set(edited.photoAssetIDs))
        #expect(direction.moments.allSatisfy { !$0.photos.isEmpty && Set($0.mustInclude) == Set($0.photos) })
        #expect(Set(direction.moments.flatMap(\.photos)) == Set(edited.photoAssetIDs))
        #expect(direction.coverCandidates.allSatisfy(edited.photoAssetIDs.contains))
        let joined = try #require(direction.moments.first { $0.photos.contains(ids[8]) })
        #expect(joined.label == companionMoment.label && companions.allSatisfy(joined.photos.contains))
        let newMoment = try #require(direction.moments.first { $0.photos.contains(ids[9]) })
        #expect(newMoment.photos == [ids[9]] && newMoment.size == "1")
        #expect(direction.moments.first == newMoment)
        #expect(!direction.moments.contains { $0.label == "moment 1" })
        #expect(try store.read(CarouselPlan.self, from: "edits/c1/plan.json") == rerolled)
        #expect(try RunSession(runDirectory: store.root).plan("c1") == rerolled)
    }

    @Test(arguments: [false, true])
    func authoredRerollFindsALaterCoverButStillFallsBackForInvalidOrder(keepOrder: Bool) async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let (store, folder, _) = try await authoredRun(tmp, exactSet: true, keepOrder: keepOrder)
        var report = try store.read(ConceptsReport.self, from: "plans/director.json")
        let index = try #require(report.plans.firstIndex { $0.id == "c1" })
        let current = report.plans[index]
        if keepOrder {
            // Interleaved moments make search's final sequence differ from the current slide order.
            let ids = current.photoAssetIDs
            report.plans[index].direction?.moments = [
                .init(label: "interleaved", photos: [ids[0], ids[2]], mustInclude: [ids[0], ids[2]], size: "few"),
                .init(label: "rest", photos: [ids[1]] + Array(ids.dropFirst(3)), mustInclude: [], size: "many")
            ]
            report.plans[0].slides.reverse() // The sibling cover is distinct; only order should reject search.
        } else {
            let cover = try #require(current.coverAssetID)
            let ids = current.photoAssetIDs
            report.plans[index].direction?.moments = [
                .init(label: "opening", photos: [cover], mustInclude: [cover], size: "1"),
                .init(label: "rest", photos: ids.filter { $0 != cover }, mustInclude: [], size: "many")
            ]
            report.plans[index].direction?.coverCandidates = [cover]
            let siblingSlide = try #require(report.plans[0].slides.firstIndex { $0.photos.first?.assetID == cover })
            report.plans[0].slides.insert(report.plans[0].slides.remove(at: siblingSlide), at: 0)
        }
        try store.write(report, to: "plans/director.json")
        let session = try RunSession(runDirectory: store.root)
        try session.setSource(folder)
        try session.reroll("c1")
        let rerolled = try #require(session.plan("c1"))
        #expect(Set(rerolled.photoAssetIDs) == Set(current.photoAssetIDs))
        let event = try #require(session.log.read().last)
        #expect(event.event == "concept_rerolled")
        let fallback = "c1: page search violated cover or order constraints; used the current engine"
        if keepOrder {
            #expect(rerolled.slides.allSatisfy { $0.placement == nil })
            #expect(rerolled.photoAssetIDs == current.photoAssetIDs)
            #expect(event.after?.contains(fallback) == true)
        } else {
            // The taken first-moment candidate no longer forces legacy composition: later
            // moments supply a fitting, distinct cover under the cover-fix policy.
            #expect(rerolled.slides.allSatisfy { $0.placement != nil })
            #expect(rerolled.coverAssetID != current.coverAssetID)
            #expect(rerolled.coverAssetID != report.plans[0].coverAssetID)
            #expect(rerolled.slides[0].placement?.pageID != "white-card")
            #expect(event.after?.contains(fallback) != true)
            let cover = try #require(rerolled.coverAssetID)
            let candidate = try #require(current.coverAssetID)
            #expect(event.after?.contains("c1: cover \(cover.rawValue) chosen because \(candidate.rawValue) fits no cover page") == true)
        }
    }

    private func authoredRun(_ tmp: TempDirectory, exactSet: Bool, keepOrder: Bool) async throws -> (RunStore, URL, [AssetID]) {
        let folder = try tmp.sub("trip")
        for i in 0..<12 {
            var exif = FixtureFactory.Exif(); exif.orientation = 6
            exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i)
            try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
        }
        var options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                                 cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
        options.exact = exactSet; options.keepOrder = keepOrder
        let model = FakeModel(); model.directions = 1
        let store = try await RunPipeline.live(options: options, client: ResponsesClient(transport: model, sleep: { _ in }), log: { _ in }).run(options)
        let session = try RunSession(runDirectory: store.root)
        let context = session.compositionContext()
        let ids = context.photos.values.sorted { $0.sourceRelativePaths[0] < $1.sourceRelativePaths[0] }.map(\.assetID)
        let selected = Array(ids.prefix(8))
        let spine = SelectionSpine(orderedAssetIDs: selected, sequenceIntent: selected.map { _ in .build }, rationale: [])
        let groups = [Array(ids[0..<3]), [ids[3]], Array(ids[4..<7]), [ids[7]]]
        let direction = Direction(brief: "edited story", style: .baseline, coverAssetID: ids[1], orderedAssetIDs: selected,
            moments: groups.enumerated().map { i, photos in
                .init(label: "moment \(i)", photos: photos, mustInclude: photos, size: photos.count == 1 ? "1" : "few")
            }, coverCandidates: [ids[1], ids[2], ids[3]])
        let set = ComposerEngine.composeSet(directions: [direction], spine: spine, context: context, runID: session.runID)
        var report = session.concepts
        report.plans = set.plans; report.presentationOrder = set.presentationOrder; report.spine = spine
        try store.write(report, to: "plans/director.json")
        return (store, folder, ids)
    }
}
