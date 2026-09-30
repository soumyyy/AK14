import Foundation
import Session
import Testing
import TestSupport
@testable import CLI
import Core
import Director
import Render

@Suite struct FinalFixE2ETests {
    @Test(arguments: [false, true])
    func reorderingRunMembersDeduplicatesAndRemapsIndices(legacySupport: Bool) throws {
        let (context, spine, direction) = try fixture()
        let set = ComposerEngine.composeSet(directions: [direction], spine: spine, context: context, runID: "blank")
        var plan = try #require(set.plans.first { !$0.isBaseline })
        #expect(plan.photoAssetIDs == spine.orderedAssetIDs)
        #expect(plan.slides.count == 3)
        try #require(plan.slides.count == 3)
        #expect(plan.slides[1].photos.first?.role == "reference")
        plan.slides[2].photos[0].role = "support"
        let beforeDecode = LayoutResolver.resolve(plan, context: layout(context))
        if legacySupport { plan.slides[1].photos[0].role = "support" }
        let decoded = try JSONCoding.decoder.decode(CarouselPlan.self, from: JSONCoding.encoder.encode(plan))
        #expect(LayoutResolver.resolve(decoded, context: layout(context)).slides == beforeDecode.slides)
        // The blank member is before the real support photo, and must never win ownership.
        for (from, to, expected) in [(2, 0, ["p1", "p0"]), (1, 0, ["p1", "p0"]), (0, 2, ["p1", "p0"]), (2, 1, ["p0", "p1"]), (2, 2, ["p0", "p1"])] {
            let edited = try PlanEditor.apply(.reorder(from: from, to: to), to: decoded)
            let resolved = LayoutResolver.resolve(edited, context: layout(context))
            let ids = resolved.slides.flatMap(\.elements).filter { $0.kind == .photo }.compactMap(\.assetID)
            #expect(ids.map(\.rawValue) == expected)
            #expect(Set(ids).count == ids.count)
            #expect(edited.photoAssetIDs == ids)
            #expect(edited.slides.count == 2)
            #expect(edited.slides.allSatisfy { $0.photos.allSatisfy { $0.role != "reference" } })
        }
    }

    @Test func keepOrderAllowsTheSameCoverAcrossDistinctAuthoredFamiliesIncludingBlankRuns() throws {
        let (context, spine, direction) = try fixture(families: 3)
        let set = ComposerEngine.composeSet(directions: Array(repeating: direction, count: 3), spine: spine, context: context, runID: "ordered")
        let options = set.plans.filter { !$0.isBaseline }
        #expect(options.count == 3)
        #expect(!set.warnings.contains { $0.contains("no family fits") })
        #expect(options.allSatisfy { $0.photoAssetIDs == spine.orderedAssetIDs })
        #expect(options.allSatisfy { $0.coverAssetID == spine.coverAssetID })
        let families = options.map { plan in Set(plan.slides.compactMap(\.placement?.pageID).compactMap { id in context.pages.first { $0.id == id }?.familyID }) }
        #expect(families.allSatisfy { $0.count == 1 })
        #expect(Set(families).count == 3)
        for option in options {
            let resolved = LayoutResolver.resolve(option, context: layout(context))
            #expect(resolved.slides.count == 3)
            try #require(resolved.slides.count == 3)
            #expect(resolved.slides[1].elements.isEmpty)
        }
    }

    @Test func coverAtANonzeroSlotIsTaggedHeroAndBaselineCoverIsReserved() throws {
        var (context, spine, direction) = try fixture()
        context.keepOrder = false
        let slots = [DesignedSet.Slot(frame: UnitRect(x: 0.1, y: 0.1, width: 0.4, height: 0.5), aspect: 0.64, z: 0, crossesSeam: false, roleHint: "support"),
                     DesignedSet.Slot(frame: UnitRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8), aspect: 0.4, z: 1, crossesSeam: false, roleHint: "hero")]
        context.pages = (0..<20).map { i in
            DesignedSet(id: "pair-\(i)", sourceRef: "test", aspect: .portrait4x5, slideCount: 1, background: "#FFFFFF", slots: slots,
                        family: "A", sourceTemplate: "pair", pageIndex: 0, pageRole: "cover", coverCapable: true)
        }
        direction.moments = [.init(label: "pair", photos: spine.orderedAssetIDs, mustInclude: spine.orderedAssetIDs, size: "few")]
        direction.coverCandidates = spine.orderedAssetIDs
        let set = ComposerEngine.composeSet(directions: [direction], spine: spine, context: context, runID: "cover")
        let option = try #require(set.plans.first { !$0.isBaseline })
        #expect(option.slides[0].placement != nil)
        #expect(option.coverAssetID?.rawValue == "p1")
        #expect(option.slides[0].photos.map(\.role) == ["support", "hero"])
        #expect(option.coverAssetID != set.plans[0].coverAssetID)
        #expect(LayoutResolver.resolve(option, context: layout(context)).slides[0].elements.contains { $0.assetID == option.coverAssetID })
    }

    @Test func rerollFallbackDoesNotDuplicateBlankRunReferences() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let folder = try tmp.sub("photos")
        for i in 0..<12 { try FixtureFactory.writeScene(to: folder.appending(path: "IMG_\(i).jpg"), scene: i) }
        let options = RunOptions(folder: folder, aspect: .portrait4x5, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
        let store = try await RunPipeline.live(options: options, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(options)
        var report = try store.read(ConceptsReport.self, from: "plans/director.json")
        let actualIDs = try store.read(IngestResult.self, from: "input-index.json").photos.prefix(2).map(\.assetID)
        let (context, spine, direction) = try fixture()
        var plan = try #require(ComposerEngine.composeSet(directions: [direction], spine: spine, context: context, runID: "reroll").plans.first { !$0.isBaseline })
        for slide in plan.slides.indices {
            for photo in plan.slides[slide].photos.indices {
                let index = plan.slides[slide].photos[photo].assetID.rawValue == "p0" ? 0 : 1
                plan.slides[slide].photos[photo].assetID = actualIDs[index]
            }
            plan.slides[slide].placement?.pageID = "missing-family"
        }
        plan.direction = Direction(brief: "reroll", style: .baseline, coverAssetID: actualIDs[0], orderedAssetIDs: actualIDs)
        report.plans = [plan]
        try store.write(report, to: "plans/director.json")
        let session = try RunSession(runDirectory: store.root)
        try session.setSource(folder)
        try session.reroll(plan.id)
        let rerolled = try #require(session.plan(plan.id))
        #expect(rerolled.photoAssetIDs.count == 2)
        #expect(Set(rerolled.photoAssetIDs) == Set(actualIDs))
        #expect(rerolled.slides.allSatisfy { $0.placement == nil })
    }

    @Test func blankRunMembersLoseToAnEquivalentOccupiedPage() throws {
        var (context, spine, direction) = try fixture()
        let runs = context.pages.filter { $0.slideCount == 2 }
        context.pages += runs.map { run in
            var single = run
            single.id = "z-occupied-" + run.id
            single.slideCount = 1
            let f = single.slots[0].frame
            single.slots[0].frame = UnitRect(x: f.x - 1, y: f.y, width: f.width, height: f.height)
            return single
        }
        let option = try #require(ComposerEngine.composeSet(directions: [direction], spine: spine, context: context, runID: "blank-penalty").plans.first { !$0.isBaseline })
        #expect(option.slides.count == 2)
        #expect(option.slides[1].placement?.pageID.hasPrefix("z-occupied-") == true)
        #expect(LayoutResolver.resolve(option, context: layout(context)).slides.allSatisfy { $0.elements.contains { $0.kind == .photo } })
    }

    @Test func invalidPageLibraryWarnsAndFallsBackThroughThePipeline() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let folder = try tmp.sub("invalid-library")
        for i in 0..<12 { try FixtureFactory.writeScene(to: folder.appending(path: "IMG_\(i).jpg"), scene: i) }
        let options = RunOptions(folder: folder, aspect: .portrait4x5, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
        var library = try StylePackLoader.loadDesignedPages()
        library.sets[0].pageRole = "invalid-role"
        let invalid = library
        var pipeline = RunPipeline.live(options: options, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in })
        pipeline.loadDesignedPages = { invalid }
        let store = try await pipeline.run(options)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        #expect(manifest.warnings.contains { $0.contains("invalid page library") && $0.contains("invalid page role") })
        let report = try store.read(ConceptsReport.self, from: "plans/director.json")
        #expect(report.plans.allSatisfy { $0.slides.allSatisfy { $0.placement == nil } })
        #expect(report.renderedSlides.values.allSatisfy { !$0.isEmpty && $0.allSatisfy { FileManager.default.fileExists(atPath: store.url($0).path) } })
    }

    @Test func compareFreezesAPlanWithABlankRunMemberWithoutDuplicatePhotos() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let folder = try tmp.sub("compare-photos")
        for i in 0..<12 { try FixtureFactory.writeScene(to: folder.appending(path: "IMG_\(i).jpg"), scene: i) }
        let options = RunOptions(folder: folder, aspect: .portrait4x5, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
        let store = try await RunPipeline.live(options: options, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(options)
        var input = try store.read(IngestResult.self, from: "input-index.json")
        input.photos = Array(input.photos.prefix(2))
        input.photos = input.photos.enumerated().map { index, photo in
            PhotoRecord(assetID: photo.assetID, contentSHA256: photo.contentSHA256, sourceRelativePaths: photo.sourceRelativePaths,
                byteCount: photo.byteCount, fileType: photo.fileType, pixelWidth: index == 0 ? 750 : 400, pixelHeight: 1000,
                exifOrientation: photo.exifOrientation, metadata: photo.metadata)
        }
        try store.write(input, to: "input-index.json")
        try store.write([PhotoFeatures](), to: "cache/features.json")
        let ids = input.photos.map(\.assetID)
        var report = try store.read(ConceptsReport.self, from: "plans/director.json")
        report.spine = SelectionSpine(orderedAssetIDs: Array(ids.reversed()), sequenceIntent: [.opener, .closer], rationale: [])
        report.pool = ids
        report.plans = [CarouselPlan(id: "c1", brief: "compare", direction:
            Direction(brief: "compare", style: .baseline, coverAssetID: ids[0], orderedAssetIDs: ids,
                moments: ids.map { .init(label: "", photos: [$0], mustInclude: [$0], size: "1") }, coverCandidates: ids), slides: [])]
        try store.write(report, to: "plans/director.json")
        var manifest = try store.read(RunManifest.self, from: "manifest.json")
        manifest.keepOrder = false; manifest.exactSet = true
        try store.write(manifest, to: "manifest.json")
        var library = try StylePackLoader.loadDesignedPages()
        library.sets = try fixture().0.pages
        let out = tmp.url.appending(path: "comparison")
        try EvalCommand.compare(runDirectories: [store.root], source: folder, out: out, loadDesignedPages: { library })
        let set = try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: out.appending(path: "evalset.json")))
        let pair = try #require(set.pairs.first)
        #expect(set.pairs.count == 1)
        #expect(pair.left.assetIDs == ids && pair.right.assetIDs == ids)
        let ref = pair.left.carouselID.hasPrefix("pages-") ? pair.left : pair.right
        let plan = try JSONCoding.decoder.decode(CarouselPlan.self, from: Data(contentsOf: out.appending(path: "runs/\(ref.runID)/plans/\(ref.carouselID).json")))
        #expect(plan.slides.count == 3)
        #expect(plan.slides[1].photos.first?.role == "reference")
        #expect(plan.photoAssetIDs == ids)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "runs/\(ref.runID)/slides/\(ref.carouselID)/slide-03.png").path))
    }

    private func fixture(families: Int = 1) throws -> (CompositionContext, SelectionSpine, Direction) {
        let photos = [0.75, 0.4].enumerated().map { i, aspect in
            PhotoRecord(assetID: AssetID(rawValue: "p\(i)"), contentSHA256: "p\(i)", sourceRelativePaths: [], byteCount: 1,
                        fileType: "public.jpeg", pixelWidth: Int(aspect * 1000), pixelHeight: 1000, exifOrientation: 1, metadata: CaptureMetadata())
        }
        let ids = photos.map(\.assetID)
        let pages = (0..<families).flatMap { family in (0..<10).flatMap { copy in [
            DesignedSet(id: "cover-\(family)-\(copy)", sourceRef: "test", aspect: .portrait4x5, slideCount: 1, background: "#FFFFFF",
                slots: [.init(frame: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), aspect: 0.75, z: 0, crossesSeam: false, roleHint: "hero")],
                family: "F\(family)", sourceTemplate: "cover", pageIndex: 0, pageRole: "cover", coverCapable: true),
            DesignedSet(id: "run-\(family)-\(copy)", sourceRef: "test", aspect: .portrait4x5, slideCount: 2, background: "#FFFFFF",
                slots: [.init(frame: UnitRect(x: 1.1, y: 0.1, width: 0.4, height: 0.8), aspect: 0.4, z: 0, crossesSeam: false, roleHint: "support")],
                family: "F\(family)", sourceTemplate: "run", pageIndex: 1, pageRole: "strip", coverCapable: false)
        ] } }
        let context = CompositionContext(aspect: .portrait4x5, photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) }),
            features: [:], triage: [:], flagged: [], sequenceIntent: [:], stylePack: try StylePackLoader.load(), maxSlides: nil,
            exactSet: true, keepOrder: true, pages: pages)
        let spine = SelectionSpine(orderedAssetIDs: ids, sequenceIntent: [.opener, .closer], rationale: [])
        let direction = Direction(brief: "blank run", style: .baseline, coverAssetID: ids[0], orderedAssetIDs: ids,
            moments: ids.map { .init(label: "", photos: [$0], mustInclude: [$0], size: "1") }, coverCandidates: ids)
        return (context, spine, direction)
    }

    private func layout(_ context: CompositionContext) -> LayoutContext {
        LayoutContext(aspect: context.aspect, photos: context.photos, features: context.features, stylePack: context.stylePack,
                      seed: 1, pages: context.pages, keepOrder: context.keepOrder)
    }
}
