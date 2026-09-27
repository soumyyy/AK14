import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Session
@testable import Render

@Test func savedDirectionsWithoutSeamlessRemainReadable() throws {
    let id = AssetID(rawValue: "photo")
    let direction = Direction(brief: "An older story", style: .baseline, coverAssetID: id,
                              orderedAssetIDs: [id])
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(direction)) as? [String: Any])
    json.removeValue(forKey: "seamless")
    let decoded = try JSONDecoder().decode(Direction.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded == direction)
    json["seamless"] = true
    #expect(try JSONDecoder().decode(Direction.self, from: JSONSerialization.data(withJSONObject: json)).seamless)
}

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

@Test func slidePairingNeedsSceneOrClosePeopleMomentEvidence() throws {
    let a = AssetID(rawValue: "a"), b = AssetID(rawValue: "b")
    func record(_ id: AssetID, _ date: Date?) -> PhotoRecord {
        PhotoRecord(assetID: id, contentSHA256: id.rawValue, sourceRelativePaths: [], byteCount: 1,
                    fileType: "public.jpeg", pixelWidth: 1600, pixelHeight: 1200, exifOrientation: 1,
                    metadata: CaptureMetadata(capturedAt: date))
    }
    var fa = PhotoFeatures(assetID: a, analyzerVersion: "test")
    var fb = PhotoFeatures(assetID: b, analyzerVersion: "test")
    fa.color = ColorProfile(l: 50, a: 5, b: 4, saturation: 0.4, warmth: 0.1, contrast: 0.2)
    fb.color = fa.color
    let style = try StylePackLoader.load()
    func context(_ photos: [AssetID: PhotoRecord], _ features: [AssetID: PhotoFeatures]) -> CompositionContext {
        CompositionContext(aspect: .portrait4x5, photos: photos, features: features, triage: [:], flagged: [],
                           sequenceIntent: [:], stylePack: style, maxSlides: nil)
    }
    #expect(!ComposerEngine.pairHasStoryLink(members: [a, b], context: context([a: record(a, nil), b: record(b, nil)], [a: fa, b: fb])),
            "matching color alone should not justify a pair")
    fa.labels = [SceneLabel(identifier: "tea_hill", confidence: 0.8)]
    fb.labels = [SceneLabel(identifier: "tea_hill", confidence: 0.7)]
    #expect(ComposerEngine.pairHasStoryLink(members: [a, b], context: context([a: record(a, nil), b: record(b, nil)], [a: fa, b: fb])))
    fa.labels = []; fb.labels = []
    let moment = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!ComposerEngine.pairHasStoryLink(members: [a, b], context: context(
        [a: record(a, moment), b: record(b, moment.addingTimeInterval(8 * 60))], [a: fa, b: fb])),
        "same-hour personless photos need shared scene evidence")
    fa.faces = [FaceRegion(box: UnitRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), captureQuality: 0.8)]
    fb.faces = fa.faces
    #expect(ComposerEngine.pairHasStoryLink(members: [a, b], context: context([a: record(a, moment), b: record(b, moment.addingTimeInterval(8 * 60))], [a: fa, b: fb])))
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
            // A multi-photo slide is only allowed where an imported template page hosts it.
            for (i, slide) in plan.slides.enumerated() where slide.primitive == .inset || slide.primitive == .overlapCluster {
                let resolved = try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", plan.id, i + 1))
                #expect(resolved.variant?.hasPrefix("template.") == true, "\(plan.id) slide \(i + 1) overlaps")
            }
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
    // The diversity step may drop a direction; use whichever direction survived.
    let directionID = try #require(session.availableConcepts.sorted().first { $0 != CarouselPlan.baselineID })
    let plan = try #require(session.plan(directionID))
    // Replay the plan's own stored seed: the diversity remedy may have composed it with an alternative seed.
    let seed = try #require(plan.compositionSeed.flatMap { UInt64($0, radix: 16) })
    let again = ComposerEngine.compose(try #require(plan.direction), id: directionID, context: session.compositionContext(),
                                       seed: seed, layoutSeed: ComposerEngine.layoutSeed(runID: session.runID, id: directionID))
    #expect(again.plan == plan)
    try session.setSource(folder)
    let calls = model.stages.count
    try session.reroll(directionID)
    #expect(model.stages.count == calls)
}

@Test func legacyRunsOpenReportAndRerenderWithoutRecomposition() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp)
    // This migration fixture needs exactly c1/c2. With three directions the diversity
    // filter may legitimately retire either one before the legacy rewrite below.
    let model = FakeModel(); model.directions = 2
    let store = try await run(tmp, folder: folder, model: model)
    // Rewrite the run into the pre-composer shape: named concept types, one distance, type-named directories.
    let names = ["baseline": "plainDump", "c1": "designed", "c2": "wildcard"]
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url("plans/director.json"))) as! [String: Any]
    json["plans"] = (json["plans"] as! [[String: Any]]).compactMap { p -> [String: Any]? in
        guard let old = names[p["id"] as! String] else { return nil }
        return ["conceptType": old, "conceptNote": p["brief"]!, "slides": p["slides"]!]
    }
    var rendered: [String: Any] = [:]
    let fm = FileManager.default
    for (new, old) in names {
        rendered[old] = ((json["renderedSlides"] as! [String: [String]])[new] ?? []).map { $0.replacingOccurrences(of: "slides/\(new)/", with: "slides/\(old)/") }
        // A recipe-filled concept (spec §3) has no `layouts/<id>`, only `documents/<id>.json`; rename whichever exists.
        for dir in ["slides", "layouts"] where fm.fileExists(atPath: store.url("\(dir)/\(new)").path) {
            try fm.moveItem(at: store.url("\(dir)/\(new)"), to: store.url("\(dir)/\(old)"))
        }
        let doc = store.url("documents/\(new).json")
        if fm.fileExists(atPath: doc.path) {
            try fm.moveItem(at: doc, to: store.url("documents/\(old).json"))
        }
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
    let fm = FileManager.default
    // A recipe-filled concept (spec §3) has no `layouts/<id>`, only `documents/<id>.json`; move whichever exists.
    for dir in ["slides", "layouts"] where fm.fileExists(atPath: store.url("\(dir)/c2").path) {
        try fm.moveItem(at: store.url("\(dir)/c2"), to: store.url("\(dir)/c9"))
    }
    let doc = store.url("documents/c2.json")
    if fm.fileExists(atPath: doc.path) { try fm.moveItem(at: doc, to: store.url("documents/c9.json")) }
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
