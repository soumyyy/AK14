import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Session

private func sceneFolder(_ tmp: TempDirectory, count: Int = 14) throws -> URL {
    let folder = try tmp.sub("trip")
    for i in 0..<count {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:05:29 %02d:%02d:00", 8 + i / 3, (i % 3) * 20)   // three photos per hour
        exif.orientation = i % 3 == 0 ? 6 : 1
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func run(_ tmp: TempDirectory, folder: URL, model: FakeModel, slides: Int? = nil) async throws -> RunStore {
    var o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    o.slides = slides
    return try await RunPipeline.live(options: o, client: ResponsesClient(transport: model, sleep: { _ in }), log: { _ in }).run(o)
}

@Test(arguments: [2, 5])
func modelDecidesHowManyDirectionsAndEveryAxisIsHonoured(count: Int) async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(); model.directions = count
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    // Grouping is aesthetic: every analysed photo carries a colour profile.
    #expect(try store.read([PhotoFeatures].self, from: "cache/features.json").allSatisfy { $0.color != nil })
    let directions = d.plans.filter { !$0.isBaseline }
    let dropped = d.warnings.filter { $0.contains("dropped") }.count
    #expect(directions.count + dropped == count && directions.count >= 2, "\(d.warnings)")
    #expect(d.plans.first?.id == "baseline" && Set(d.presentationOrder) == Set(d.plans.map(\.id)))
    #expect(d.diversity.count == directions.count * (directions.count - 1) / 2)

    for plan in d.plans {
        let style = try #require(plan.style, "\(plan.id) has no direction")
        #expect(plan.slides[0].photos.count == 1, "\(plan.id): the cover shares its slide")
        #expect(d.renderedSlides[plan.id]?.count == plan.slides.count)
        let decorated = plan.slides.filter { !$0.decorations.isEmpty || !$0.stamps.isEmpty }.count
        switch style.decoration {
        case "none": #expect(decorated == 0 && !plan.slides.contains { $0.primitive == .framedHero }, "\(plan.id) decorated")
        case "light": #expect(decorated <= plan.slides.count / 5, "\(plan.id): \(decorated) decorated slides")
        default: #expect(decorated <= plan.slides.count / 2, "\(plan.id): \(decorated) decorated slides")
        }
        if style.grouping == "single" { #expect(plan.slides.allSatisfy { $0.photos.count == 1 }, "\(plan.id) grouped photos") }
        if style.overlap == "none" {
            #expect(!plan.slides.contains { $0.primitive == .inset || $0.primitive == .overlapCluster }, "\(plan.id) overlaps")
        }
        if style.rotation == "none" { #expect(plan.slides.allSatisfy { $0.photos.allSatisfy { $0.rotationIntent == "none" } }) }
        for slide in plan.slides where slide.photos.count > 1 {
            #expect(slide.photos.filter { $0.role == "hero" }.count == 1)
        }
    }
    let baseline = try #require(d.baseline)
    #expect(baseline.photoAssetIDs == d.spine?.orderedAssetIDs)
    #expect(baseline.slides.allSatisfy { [.fullBleed, .hero].contains($0.primitive) && $0.decorations.isEmpty && $0.stamps.isEmpty })
}

@Test func oneInvalidDirectionIsDroppedAndTheRestAreComposed() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.badDirection], "repair": [.badDirection], "retry": [.badDirection]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.status == "partial")
    #expect(d.plans.map(\.id) == ["baseline", "c1", "c2"])
    #expect(d.unavailable["directions"]?.contains("1 of 3") == true)
}

@Test func compositionIsDeterministicAndRerollNeedsNoModel() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let model = FakeModel()
    let store = try await run(tmp, folder: folder, model: model)
    let session = try RunSession(runDirectory: store.root)
    let plan = try #require(session.plan("c1"))
    // Replay the plan's own stored seed: the diversity remedy may have composed it with an alternative seed.
    let seed = try #require(plan.compositionSeed.flatMap { UInt64($0, radix: 16) })
    let again = ComposerEngine.compose(try #require(plan.direction), id: "c1", context: session.compositionContext(),
                                       seed: seed, layoutSeed: ComposerEngine.layoutSeed(runID: session.runID, id: "c1"))
    #expect(again.plan == plan)
    try session.setSource(folder)
    let calls = model.stages.count
    try session.reroll("c1")
    #expect(model.stages.count == calls)
}

@Test func legacyRunsOpenReportAndRerenderWithoutRecomposition() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let store = try await run(tmp, folder: folder, model: FakeModel())
    // Rewrite the run into the pre-composer shape: named concept types, one distance, type-named directories.
    let names = ["baseline": "plainDump", "c1": "designed", "c2": "wildcard"]
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url("plans/director.json"))) as! [String: Any]
    json["plans"] = (json["plans"] as! [[String: Any]]).compactMap { p -> [String: Any]? in
        guard let old = names[p["id"] as! String] else { return nil }
        return ["conceptType": old, "conceptNote": p["brief"]!, "slides": p["slides"]!]
    }
    var rendered: [String: Any] = [:]
    for (new, old) in names {
        rendered[old] = ((json["renderedSlides"] as! [String: [String]])[new] ?? []).map { $0.replacingOccurrences(of: "slides/\(new)/", with: "slides/\(old)/") }
        for dir in ["slides", "layouts"] { try FileManager.default.moveItem(at: store.url("\(dir)/\(new)"), to: store.url("\(dir)/\(old)")) }
    }
    json["renderedSlides"] = rendered
    json["diversity"] = (json["diversity"] as! [[String: Any]]).first.map { d in d.filter { !["a", "b", "styleDistance"].contains($0.key) } }
    json.removeValue(forKey: "presentationOrder")
    try JSONSerialization.data(withJSONObject: json).write(to: store.url("plans/director.json"))

    let legacy = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(legacy.plans.map(\.id) == ["plainDump", "designed", "wildcard"] && legacy.baseline?.id == "plainDump")
    #expect(legacy.diversity.first?.a == "designed")
    try RerenderCommand.rerender(runDirectory: store.root, source: folder)
    let after = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(after.plans == legacy.plans)                                  // never recomposed
    #expect(FileManager.default.fileExists(atPath: store.url("slides/designed/slide-01.png").path))
    try ReportCommand.rebuild(runDirectory: store.root)
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    let before = try #require(session.plan("wildcard"))
    try session.reroll("wildcard")                                         // no direction: new geometry only
    #expect(session.plan("wildcard") == before)
    try session.select("plainDump"); try session.export("plainDump", to: tmp.url.appending(path: "out"))
    let summary = StudySummary.compute(runsDirectory: tmp.url.appending(path: "runs"))
    #expect(summary.participants.isEmpty)                                  // no study code, but the run is readable
}

@Test func recomposeKeepsIdsReplaysSeedsAndRespectsTheSlideLimit() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    let model = FakeModel(); model.directions = 4
    let store = try await run(tmp, folder: folder, model: model, slides: 6)
    var d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.requestedSlides == 6)
    #expect(d.plans.allSatisfy { $0.slides.count <= 6 }, "\(d.plans.map { ($0.id, $0.slides.count) })")
    #expect(d.plans.allSatisfy { $0.compositionSeed != nil })

    // A direction dropped at planning time leaves a gap (c1, c3): recomposition must keep ids, not renumber.
    let i = try #require(d.plans.firstIndex { $0.id == "c2" })
    d.plans[i].id = "c9"
    d.presentationOrder = d.presentationOrder.map { $0 == "c2" ? "c9" : $0 }
    d.renderedSlides["c9"] = d.renderedSlides.removeValue(forKey: "c2")?.map { $0.replacingOccurrences(of: "/c2/", with: "/c9/") }
    for dir in ["slides", "layouts"] { try FileManager.default.moveItem(at: store.url("\(dir)/c2"), to: store.url("\(dir)/c9")) }
    try store.write(d, to: "plans/director.json")
    try RerenderCommand.rerender(runDirectory: store.root, source: folder, recompose: true)
    let after = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(after.plans.map(\.id) == d.plans.map(\.id))
    for (a, b) in zip(after.plans, d.plans) where a.id != "c9" { #expect(a == b, "\(a.id) changed on recompose") }

    // Studio reroll respects the limit too, and exports never name the baseline.
    let session = try RunSession(runDirectory: store.root)
    try session.setSource(folder)
    for id in session.availableConcepts where !(session.plan(id)?.isBaseline ?? true) {
        try session.reroll(id)
        #expect((session.plan(id)?.slides.count ?? 99) <= 6)
    }
    let files = try session.export("baseline", to: tmp.url.appending(path: "out"))
    #expect(files.allSatisfy { !$0.lastPathComponent.contains("baseline") })
}
