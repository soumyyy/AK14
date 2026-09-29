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

@Test func storyLinkedLandscapesStackOnImportedPages() throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("landscapes")
    let moment = Date(timeIntervalSince1970: 1_800_000_000)
    let sceneLabel = SceneLabel(identifier: "harbor_pier", confidence: 0.85)
    func writeLandscape(_ name: String, minutes: Int) throws -> AssetID {
        let id = AssetID(rawValue: name)
        var exif = FixtureFactory.Exif()
        let t = moment.addingTimeInterval(Double(minutes * 60))
        exif.date = String(format: "%04d:%02d:%02d %02d:%02d:00",
                           Calendar.current.component(.year, from: t),
                           Calendar.current.component(.month, from: t),
                           Calendar.current.component(.day, from: t),
                           Calendar.current.component(.hour, from: t),
                           Calendar.current.component(.minute, from: t))
        try FixtureFactory.writeJPEG(to: folder.appending(path: "\(name).jpg"), width: 4032, height: 1512, gray: 0.55, exif: exif)
        return id
    }
    func writePortrait(_ name: String, gray: Double) throws -> AssetID {
        let id = AssetID(rawValue: name)
        try FixtureFactory.writeJPEG(to: folder.appending(path: "\(name).jpg"), width: 3024, height: 4032, gray: gray, exif: FixtureFactory.Exif())
        return id
    }
    let l1 = try writeLandscape("l1", minutes: 0)
    let l2 = try writeLandscape("l2", minutes: 4)
    let l3 = try writeLandscape("l3", minutes: 8)
    let p1 = try writePortrait("p1", gray: 0.35)
    let p2 = try writePortrait("p2", gray: 0.45)
    let p3 = try writePortrait("p3", gray: 0.55)
    let p4 = try writePortrait("p4", gray: 0.65)
    let p5 = try writePortrait("p5", gray: 0.75)
    // Three 16:9 landscapes from the same scene; grouping should stack them on 1x3 when vocabulary is present.
    let ordered = [p1, l1, l2, l3, p2, p3, p4, p5]
    func record(_ id: AssetID, w: Int, h: Int, date: Date?) -> PhotoRecord {
        PhotoRecord(assetID: id, contentSHA256: id.rawValue, sourceRelativePaths: ["\(id.rawValue).jpg"], byteCount: 1,
                    fileType: "public.jpeg", pixelWidth: w, pixelHeight: h, exifOrientation: 1,
                    metadata: CaptureMetadata(capturedAt: date))
    }
    let photos: [AssetID: PhotoRecord] = [
        l1: record(l1, w: 4032, h: 1512, date: moment),
        l2: record(l2, w: 4032, h: 1512, date: moment.addingTimeInterval(4 * 60)),
        l3: record(l3, w: 4032, h: 1512, date: moment.addingTimeInterval(8 * 60)),
        p1: record(p1, w: 3024, h: 4032, date: nil),
        p2: record(p2, w: 3024, h: 4032, date: nil),
        p3: record(p3, w: 3024, h: 4032, date: nil),
        p4: record(p4, w: 3024, h: 4032, date: nil),
        p5: record(p5, w: 3024, h: 4032, date: nil),
    ]
    var features: [AssetID: PhotoFeatures] = [:]
    for id in ordered {
        var f = PhotoFeatures(assetID: id, analyzerVersion: "test")
        f.aestheticScore = 0.7
        f.color = ColorProfile(l: 50, a: 4, b: 3, saturation: 0.4, warmth: 0.1, contrast: 0.2)
        if [l1, l2, l3].contains(id) { f.labels = [sceneLabel] }
        features[id] = f
    }
    let stylePack = try StylePackLoader.load()
    let vocabulary = try StylePackLoader.loadDesignedSets().vocabulary(for: .portrait4x5)
    #expect(vocabulary.contains { $0.id.contains("1x1v") || $0.id.contains("1x3") })

    func heroCleanCount(plan: CarouselPlan, vocabulary: [DesignedSet], seed: UInt64) -> Int {
        let layout = LayoutResolver.resolve(plan, context: LayoutContext(aspect: .portrait4x5, photos: photos,
            features: features, stylePack: stylePack, seed: seed, vocabulary: plan.isBaseline ? [] : vocabulary))
        return layout.slides.filter { $0.variant == "hero.clean" }.count
    }
    func hasLandscapeStackTemplate(plan: CarouselPlan, vocabulary: [DesignedSet], seed: UInt64) -> Bool {
        let layout = LayoutResolver.resolve(plan, context: LayoutContext(aspect: .portrait4x5, photos: photos,
            features: features, stylePack: stylePack, seed: seed, vocabulary: vocabulary))
        return layout.slides.contains { slide in
            guard let variant = slide.variant else { return false }
            return variant.contains("1x1v") || variant.contains("1x3")
        }
    }
    func compose(grouping: String, vocabulary: [DesignedSet]) -> (CarouselPlan, UInt64) {
        let seed: UInt64 = 0x7a14
        let layoutSeed = ComposerEngine.layoutSeed(runID: "stack-test", id: "c1")
        let style = StyleVector(density: "balanced", overlap: "none", grouping: grouping, decoration: "none",
                                rotation: "none", whitespace: "tight")
        let direction = Direction(brief: "landscape moment", style: style, coverAssetID: p1, orderedAssetIDs: ordered)
        let context = CompositionContext(aspect: .portrait4x5, photos: photos, features: features, triage: [:],
                                         flagged: [], sequenceIntent: [:], stylePack: stylePack, maxSlides: nil,
                                         vocabulary: vocabulary)
        let result = ComposerEngine.compose(direction, id: "c1", context: context, seed: seed, layoutSeed: layoutSeed)
        return (result.plan, layoutSeed)
    }

    let (singlePlan, singleSeed) = compose(grouping: "single", vocabulary: vocabulary)
    let (mixedPlan, mixedSeed) = compose(grouping: "mixed", vocabulary: vocabulary)
    #expect(hasLandscapeStackTemplate(plan: singlePlan, vocabulary: vocabulary, seed: singleSeed))
    #expect(hasLandscapeStackTemplate(plan: mixedPlan, vocabulary: vocabulary, seed: mixedSeed))

    let (emptySingle, emptySingleSeed) = compose(grouping: "single", vocabulary: [])
    let (emptyMixed, emptyMixedSeed) = compose(grouping: "mixed", vocabulary: [])
    let withVocabHero = heroCleanCount(plan: singlePlan, vocabulary: vocabulary, seed: singleSeed)
        + heroCleanCount(plan: mixedPlan, vocabulary: vocabulary, seed: mixedSeed)
    let withoutVocabHero = heroCleanCount(plan: emptySingle, vocabulary: [], seed: emptySingleSeed)
        + heroCleanCount(plan: emptyMixed, vocabulary: [], seed: emptyMixedSeed)
    #expect(withVocabHero < withoutVocabHero)
}

@Test func fourByThreeLandscapeBelowTheSharedFloorUsesAHero() throws {
    let id = AssetID(rawValue: "landscape")
    let photo = PhotoRecord(assetID: id, contentSHA256: "landscape", sourceRelativePaths: [],
                            byteCount: 1, fileType: "public.jpeg", pixelWidth: 1200, pixelHeight: 900,
                            exifOrientation: 1, metadata: CaptureMetadata())
    var feature = PhotoFeatures(assetID: id, analyzerVersion: "test")
    feature.salientRegions = [UnitRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)]
    let style = try StylePackLoader.load()
    let context = CompositionContext(aspect: .portrait4x5, photos: [id: photo], features: [id: feature],
                                     triage: [:], flagged: [], sequenceIntent: [:], stylePack: style,
                                     maxSlides: nil)
    var rng = SeededRandom(seed: 7)
    #expect(ComposerEngine.choosePrimitive(hero: id, others: [], style: .baseline, position: .opener,
                                           density: "balanced", context: context, rng: &rng) == .hero)
    #expect(ComposerEngine.floats(id, context: context))

    var peopleCut = feature
    peopleCut.humans = [UnitRect(x: 0.05, y: 0.2, width: 0.8, height: 0.5)]
    let unsafePeople = contextWith(feature: peopleCut, photo: photo, style: style)
    var peopleRNG = SeededRandom(seed: 7)
    #expect(ComposerEngine.choosePrimitive(hero: id, others: [], style: .baseline, position: .opener,
                                           density: "balanced", context: unsafePeople, rng: &peopleRNG) == .hero)

    var salientCut = feature
    salientCut.salientRegions = [UnitRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4)]
    let unsafeSaliency = contextWith(feature: salientCut, photo: photo, style: style)
    var salientRNG = SeededRandom(seed: 7)
    #expect(ComposerEngine.choosePrimitive(hero: id, others: [], style: .baseline, position: .opener,
                                           density: "balanced", context: unsafeSaliency, rng: &salientRNG) == .hero)
    #expect(ComposerEngine.floats(id, context: unsafeSaliency))
}

@Test func distinctOptionsUseStrictPhotoAndStyleSignals() {
    let ids = (1...5).map { AssetID(rawValue: "photo-\($0)") }
    func plan(_ id: String, _ order: [AssetID], _ style: StyleVector) -> CarouselPlan {
        let direction = Direction(brief: id, style: style, coverAssetID: order[0], orderedAssetIDs: order)
        return CarouselPlan(id: id, brief: id, direction: direction, slides: order.map {
            SlidePlan(primitive: .fullBleed, mood: "", density: style.density,
                      photos: [.plain($0)], decorations: [], stamps: [])
        })
    }
    let dense = StyleVector(density: "dense", overlap: "none", grouping: "single",
                            decoration: "none", rotation: "none", whitespace: "tight")
    let quiet = StyleVector(density: "quiet", overlap: "none", grouping: "single",
                            decoration: "none", rotation: "none", whitespace: "tight")
    let same = PlanMetrics.diversity(plan("same-a", ids, dense), plan("same-b", ids, quiet))
    #expect(!same.passes)

    let reversed = PlanMetrics.diversity(plan("reverse-a", ids, dense),
                                         plan("reverse-b", Array(ids.reversed()), quiet))
    #expect(reversed.jaccard == 1)
    #expect(reversed.orderSimilarity <= 0.3)
    #expect(reversed.passes)
}

private func contextWith(feature: PhotoFeatures, photo: PhotoRecord, style: StylePack) -> CompositionContext {
    CompositionContext(aspect: .portrait4x5, photos: [photo.assetID: photo], features: [photo.assetID: feature],
                       triage: [:], flagged: [], sequenceIntent: [:], stylePack: style, maxSlides: nil)
}
