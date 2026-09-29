import Core
import Foundation
import Render
import Testing

@Suite struct PageSearchE2ETests {
    @Test func searchFillsEverySlideWithAuthoredPagesFromOneFamily() throws {
        let ctx = try context(pool: portraits(6) + landscapes(2), pages: familyA + familyB)
        let d = direction(momentsOf: [["p0"], ["p1", "p2", "p3"], ["l0", "l1"], ["p4", "p5"]], cover: ["p0"], title: "Up in the clouds")
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA + familyB, context: ctx, seed: 7))
        #expect(result.plan.slides.allSatisfy { $0.placement != nil })
        #expect(result.whiteCards == 0)
        #expect(result.plan.slides.compactMap { $0.placement?.pageID }.allSatisfy { id in familyA.contains { $0.id == id } })
        #expect(result.plan.slides[0].placement.map { p in familyA.first { $0.id == p.pageID }?.coverCapable } == true)
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides[0].elements.filter { $0.textRole == "title" }.count == 1)
        #expect(layout.slides.dropFirst().allSatisfy { !$0.elements.contains { $0.textRole == "title" } })
        #expect(layout.slides.flatMap(\.elements).filter { $0.kind == .photo }.allSatisfy { ($0.crop?.width ?? 1) * ($0.crop?.height ?? 1) >= SlotAssignment.cropFloor })
        #expect(layout.slides.map(\.elements) == result.plan.slides.compactMap { $0.placement?.slide?.elements })
    }

    @Test func sameSeedSameCarousel() throws {
        let ctx = try context(pool: portraits(6) + landscapes(2), pages: familyA)
        let d = direction(momentsOf: [["p0"], ["p1", "p2", "p3"], ["l0", "l1"], ["p4", "p5"]], cover: ["p0"], title: nil)
        let a = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 7)).plan
        let b = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA.reversed(), context: ctx, seed: 7)).plan
        #expect(a == b)
        #expect(LayoutResolver.resolve(a, context: layoutContext(ctx)).slides == LayoutResolver.resolve(b, context: layoutContext(ctx)).slides)
    }

    @Test func exactSetKeepsEveryPhotoIncludingAPanoramaThatFitsNothing() throws {
        var pool = portraits(19); pool.append(photo("pano", aspect: 16.0 / 9.0 * 1.6))
        let ctx = try context(pool: pool, pages: familyA, exactSet: true)
        let d = direction(momentsOf: pool.map { [$0.assetID.rawValue] }, cover: ["p0"], title: nil)
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
        #expect(Set(result.plan.photoAssetIDs) == Set(pool.map(\.assetID)))
        #expect(result.whiteCards == 1)
        #expect(result.warnings.contains { $0.contains("pano") })
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.first { $0.elements.contains { $0.assetID?.rawValue == "pano" } }?.variant == "hero.clean")
        #expect(layout.slides.flatMap(\.elements).compactMap(\.assetID).count == pool.count)
    }

    @Test func mustIncludeIsHardAndKeepOrderIsRespected() throws {
        let ctx = try context(pool: portraits(8), pages: familyA, exactSet: true, keepOrder: true)
        let ids = (0..<8).map { "p\($0)" }
        let d = direction(momentsOf: [Array(ids[0..<3]), Array(ids[3..<8])], cover: ["p0"], title: nil)
        let plan = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 3)).plan
        let layout = LayoutResolver.resolve(plan, context: layoutContext(ctx))
        let reading = layout.slides.flatMap { slide in
            slide.elements.filter { $0.kind == .photo }.sorted {
                let a = $0.frame, b = $1.frame
                return abs((a.y + a.height / 2) - (b.y + b.height / 2)) > 0.05
                    ? a.y + a.height / 2 < b.y + b.height / 2 : a.x + a.width / 2 < b.x + b.width / 2
            }.compactMap(\.assetID?.rawValue)
        }
        #expect(reading == ids)
    }

    @Test func sixtyPhotoPoolStaysInsideTheSimulatorGuard() throws {
        let pool = portraits(40) + landscapes(20)
        let ctx = try context(pool: pool, pages: familyA + familyB)
        let d = direction(momentsOf: stride(from: 0, to: 60, by: 6).map { i in pool[i..<min(i + 6, 60)].map(\.assetID.rawValue) }, cover: ["p0"], title: "t")
        let clock = ContinuousClock()
        var result: PageSearch.Result?
        let elapsed = clock.measure { result = PageSearch.search(d, id: "c1", family: "A", pages: familyA + familyB, context: ctx, seed: 1) }
        #expect(elapsed < .seconds(2), "search took \(elapsed)")
        let plan = try #require(result).plan
        #expect(!LayoutResolver.resolve(plan, context: layoutContext(ctx)).slides.isEmpty)
    }

    @Test func identicalGeometryWithDifferentIDsDoesNotRepeatWhenAnAlternativeFits() throws {
        let cover = familyA[0]
        var first = familyA[1]; first.id = "a-first"; first.sourceTemplate = "duplicate"; first.pageIndex = 1
        var duplicate = first; duplicate.id = "b-duplicate"; duplicate.pageIndex = 2
        let alternative = page("z-alternative", family: "A", slots: [slot(0.1, 0.05, 0.8, 0.8, 0.8)], role: "statement")
        let pages = [cover, first, duplicate, alternative]
        let ctx = try context(pool: portraits(3), pages: pages, exactSet: true)
        let d = direction(momentsOf: [["p0"], ["p1"], ["p2"]], cover: ["p0"], title: nil)
        let plan = try #require(PageSearch.search(d, id: "c1", family: "A", pages: pages, context: ctx, seed: 1)).plan
        let layout = LayoutResolver.resolve(plan, context: layoutContext(ctx))
        #expect(layout.slides.count == 3)
        #expect(plan.slides.dropFirst().contains { $0.placement?.pageID == alternative.id })
        #expect(layout.slides[1].elements.first?.frame != layout.slides[2].elements.first?.frame)
    }

    @Test func borrowedPhotoCountsTowardItsMomentAndMandatoryAlternativesSurvive() throws {
        let pool = portraits(9) + [photo("pano", aspect: 2.844)]
        let ctx = try context(pool: pool, pages: familyA)
        var d = direction(momentsOf: [["p0"], ["p1", "p2"], ["p3", "p4", "p5", "p6", "p7", "p8", "pano"]], cover: ["p0"], title: nil)
        d.moments[1].mustInclude = [AssetID(rawValue: "p1"), AssetID(rawValue: "p2")]
        d.moments[2].mustInclude = [AssetID(rawValue: "pano")]
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
        let ids = LayoutResolver.resolve(result.plan, context: layoutContext(ctx)).slides.flatMap(\.elements).compactMap(\.assetID)
        #expect(ids.contains(AssetID(rawValue: "pano")))
        #expect(ids.contains(AssetID(rawValue: "p1")))
        #expect(ids.contains(AssetID(rawValue: "p2")))
        #expect(Set(ids).count == ids.count)
        #expect(result.whiteCards == 1)
    }

    @Test func legacyGroupsAndExcludedCoverReachTheRenderer() throws {
        let ctx = try context(pool: portraits(4), pages: familyA, exactSet: true)
        let ids = portraits(4).map(\.assetID)
        let d = Direction(brief: "legacy", style: .baseline, coverAssetID: ids[0], orderedAssetIDs: ids,
                          keepTogether: [[ids[2], ids[1]]], coverCandidates: [ids[0], ids[3]])
        let moments = PageSearch.legacyMoments(d)
        #expect(moments.map(\.photos) == [[ids[0]], [ids[1], ids[2]], [ids[3]]])
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1, excludedCovers: [ids[0]]))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.first?.elements.contains { $0.assetID == ids[3] } == true)
        #expect(Set(layout.slides.flatMap(\.elements).compactMap(\.assetID)) == Set(ids))
        #expect(PageSearch.candidateFamilies(familyB + familyA, photos: ids, context: ctx) == ["A", "B"])
    }

    @Test func titleBonusRequiresATitleThatActuallyRenders() throws {
        let page = page("cover", family: "A", slots: [slot(0, 0, 1, 1, 0.8)], role: "statement", cover: true)
        let pool = [photo("p0", aspect: 0.8)]
        var ctx = try context(pool: pool, pages: [page])
        let untitled = direction(momentsOf: [["p0"]], cover: ["p0"], title: nil)
        let titled = direction(momentsOf: [["p0"]], cover: ["p0"], title: "Cloud days")
        let a = try #require(PageSearch.search(untitled, id: "c1", family: "A", pages: [page], context: ctx, seed: 1))
        let b = try #require(PageSearch.search(titled, id: "c1", family: "A", pages: [page], context: ctx, seed: 1))
        #expect(b.score - a.score == 0.5)
        #expect(LayoutResolver.resolve(b.plan, context: layoutContext(ctx)).slides[0].elements.contains { $0.textRole == "title" })
        var features = PhotoFeatures(assetID: pool[0].assetID, analyzerVersion: "test")
        features.humans = [UnitRect(x: 0, y: 0, width: 1, height: 1)]
        ctx.features[pool[0].assetID] = features
        let blocked = try #require(PageSearch.search(titled, id: "c1", family: "A", pages: [page], context: ctx, seed: 1))
        #expect(blocked.score == a.score)
        #expect(!LayoutResolver.resolve(blocked.plan, context: layoutContext(ctx)).slides[0].elements.contains { $0.textRole == "title" })
    }

    @Test func runMemberReferenceRemovalKeepsTheRunLength() throws {
        let run = DesignedSet(id: "run", sourceRef: "test", aspect: .portrait4x5, slideCount: 2, background: "#FFFFFF",
                              slots: [slot(0.8, 0.1, 0.4, 0.8, 0.4)], family: "A", sourceTemplate: "run", pageIndex: 1, pageRole: "strip")
        let pages = [familyA[0], run]
        let ctx = try context(pool: [photo("p0", aspect: 0.75), photo("p1", aspect: 0.4)], pages: pages, exactSet: true)
        let d = direction(momentsOf: [["p0"], ["p1"]], cover: ["p0"], title: nil)
        let plan = try #require(PageSearch.search(d, id: "c1", family: "A", pages: pages, context: ctx, seed: 1)).plan
        #expect(plan.slides.count == 3)
        #expect(plan.slides[1].photos.first?.role == "support")
        let layout = LayoutResolver.resolve(plan, context: layoutContext(ctx))
        #expect(layout.slides[1].elements.contains { $0.assetID?.rawValue == "p1" })
        #expect(layout.slides[2].elements.contains { $0.assetID?.rawValue == "p1" })
        let edited = try PlanEditor.apply(.remove(slide: 1, photo: AssetID(rawValue: "p1")), to: plan)
        #expect(edited.slides.count == 3)
        #expect(edited.slides[1].placement == nil)
        #expect(edited.slides[1].photos == plan.slides[1].photos)
        #expect(LayoutResolver.resolve(edited, context: layoutContext(ctx)).slides.count == 3)
    }

    @Test func nonAdjacentCoverIsConsumedFromItsOwnMomentWithoutAMovePenalty() throws {
        let pages = [familyA[0], familyA[1]]
        let ctx = try context(pool: portraits(3), pages: pages, exactSet: true)
        let adjacent = direction(momentsOf: [["p0"], ["p1"], ["p2"]], cover: ["p0"], title: nil)
        let remote = direction(momentsOf: [["p0"], ["p1"], ["p2"]], cover: ["p2"], title: nil)
        let a = try #require(PageSearch.search(adjacent, id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let b = try #require(PageSearch.search(remote, id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let ids = LayoutResolver.resolve(b.plan, context: layoutContext(ctx)).slides.flatMap(\.elements).compactMap(\.assetID)
        #expect(ids.map(\.rawValue) == ["p2", "p0", "p1"])
        #expect(b.score == a.score)
        #expect(b.warnings.isEmpty)
    }

    @Test func keepOrderIgnoresCoverCandidatesAndExclusions() throws {
        let ctx = try context(pool: portraits(3), pages: familyA, exactSet: true, keepOrder: true)
        let d = direction(momentsOf: [["p0"], ["p1"], ["p2"]], cover: ["p2"], title: nil)
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1,
                                                  excludedCovers: [AssetID(rawValue: "p0")]))
        #expect(LayoutResolver.resolve(result.plan, context: layoutContext(ctx)).slides.flatMap(\.elements).compactMap(\.assetID?.rawValue) == ["p0", "p1", "p2"])
        #expect(result.warnings.isEmpty)
    }

    @Test func excludedAndUnusableCoversFallBackWithWarnings() throws {
        let pool = portraits(2) + [photo("pano", aspect: 2.844)]
        let ctx = try context(pool: pool, pages: familyA, exactSet: true)
        let d = direction(momentsOf: [["p0", "p1"], ["pano"]], cover: ["pano"], title: nil)
        for exclusions: Set<AssetID> in [[], [AssetID(rawValue: "p0")], Set(pool.map(\.assetID))] {
            let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1, excludedCovers: exclusions))
            let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
            #expect(layout.slides[0].elements.first { $0.kind == .photo }?.assetID?.rawValue == (exclusions.count == 1 ? "p1" : "p0"))
            #expect(Set(layout.slides.flatMap(\.elements).compactMap(\.assetID)) == Set(pool.map(\.assetID)))
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func emptyCatalogueStillKeepsALongExactSetOnWhiteCards() throws {
        let pool = portraits(45)
        let ctx = try context(pool: pool, pages: [], exactSet: true)
        let d = direction(momentsOf: pool.map { [$0.assetID.rawValue] }, cover: ["p0"], title: nil)
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: [], context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.count == 45)
        #expect(layout.slides.allSatisfy { $0.variant == "hero.clean" })
        #expect(layout.slides.flatMap(\.elements).compactMap(\.assetID) == pool.map(\.assetID))
        #expect(result.whiteCards == 45)
        #expect(PageSearch.search(direction(momentsOf: [], cover: [], title: nil), id: "empty", family: "A", pages: [], context: ctx, seed: 1) == nil)
    }

    @Test func authoredBlankRunMemberReplaysWithoutInventingAPhoto() throws {
        let run = DesignedSet(id: "blank-run", sourceRef: "test", aspect: .portrait4x5, slideCount: 2, background: "#FFFFFF",
                              slots: [slot(1.1, 0.1, 0.8, 0.8, 0.4)], family: "A", sourceTemplate: "blank", pageIndex: 1, pageRole: "strip")
        let pages = [familyA[0], run]
        let ctx = try context(pool: [photo("p0", aspect: 0.75), photo("p1", aspect: 0.4)], pages: pages, exactSet: true)
        let result = try #require(PageSearch.search(direction(momentsOf: [["p0"], ["p1"]], cover: ["p0"], title: nil),
                                                  id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.count == 3)
        #expect(layout.slides[1].elements.isEmpty)
        #expect(layout.slides[2].elements.compactMap(\.assetID?.rawValue) == ["p1"])
        #expect(result.plan.slides[1].photos.first?.role == "support")
    }

    @Test func borrowingSatisfiesTheNextMomentsCount() throws {
        let triple = page("triple", family: "A", slots: (0..<3).map {
            slot(0.05 + Double($0) * 0.3, 0.1, 0.25, 0.8, 0.4)
        }, role: "strip")
        let pages = [familyA[0], triple]
        let pool = [photo("p0", aspect: 0.75)] + (1..<5).map { photo("p\($0)", aspect: 0.4) }
        let ctx = try context(pool: pool, pages: pages)
        var d = direction(momentsOf: [["p0"], ["p1", "p2"], ["p3", "p4"]], cover: ["p0"], title: nil)
        d.moments[1].mustInclude = d.moments[1].photos
        d.moments[2].size = "1"
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.count == 2)
        #expect(layout.slides.flatMap(\.elements).compactMap(\.assetID?.rawValue) == ["p0", "p1", "p2", "p3"])
        #expect(result.whiteCards == 0)
    }

    @Test func mandatoryPhotosOverrideASmallerMomentSize() throws {
        let pool = portraits(5)
        let ctx = try context(pool: pool, pages: familyA)
        var d = direction(momentsOf: [pool.map(\.assetID.rawValue)], cover: ["p0"], title: nil)
        d.moments[0].mustInclude = pool.map(\.assetID)
        d.moments[0].size = "1"
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
        #expect(Set(LayoutResolver.resolve(result.plan, context: layoutContext(ctx)).slides.flatMap(\.elements).compactMap(\.assetID)) == Set(pool.map(\.assetID)))
    }

    @Test func facesAcrossAnAuthoredSeamUseAWholePhotoWhiteCard() throws {
        let run = DesignedSet(id: "seam", sourceRef: "test", aspect: .portrait4x5, slideCount: 2, background: "#FFFFFF",
                              slots: [slot(0.8, 0.1, 0.4, 0.8, 0.4)], family: "A", sourceTemplate: "seam", pageIndex: 1, pageRole: "strip")
        let pages = [familyA[0], run]
        let pool = [photo("p0", aspect: 0.75), photo("p1", aspect: 0.4)]
        var ctx = try context(pool: pool, pages: pages, exactSet: true)
        var features = PhotoFeatures(assetID: pool[1].assetID, analyzerVersion: "test")
        features.humans = [UnitRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)]
        ctx.features[pool[1].assetID] = features
        let d = direction(momentsOf: [["p0"], ["p1"]], cover: ["p0"], title: nil)
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.count == 2)
        #expect(layout.slides[1].variant == "hero.clean")
        #expect(layout.slides[1].elements.first?.crop == UnitRect(x: 0, y: 0, width: 1, height: 1))
        #expect(result.whiteCards == 1)
        #expect(result.warnings.contains { $0.contains("p1") })
    }

    @Test func requestedSlideCountIsASoftScoringTarget() throws {
        let ctx = try context(pool: portraits(1), pages: familyA)
        var target = ctx
        target.maxSlides = 5
        let d = direction(momentsOf: [["p0"]], cover: ["p0"], title: nil)
        let a = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
        let b = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: target, seed: 1))
        #expect(LayoutResolver.resolve(a.plan, context: layoutContext(ctx)).slides == LayoutResolver.resolve(b.plan, context: layoutContext(target)).slides)
        #expect(a.score - b.score == 1.5)
    }

    @Test func keepOrderWinsOverNonContiguousLegacyGroups() throws {
        let pool = portraits(4)
        let ctx = try context(pool: pool, pages: familyA, exactSet: true, keepOrder: true)
        let ids = pool.map(\.assetID)
        let d = Direction(brief: "legacy order", style: .baseline, coverAssetID: ids[3], orderedAssetIDs: ids,
                          keepTogether: [[ids[0], ids[2]]], coverCandidates: [ids[3]])
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides.flatMap(\.elements).filter { $0.kind == .photo }.compactMap(\.assetID) == ids)
    }

    @Test func remoteCoverAndBorrowStillRespectTheDestinationSize() throws {
        let cover = page("two-cover", family: "A", slots: [slot(0.05, 0.05, 0.9, 0.4, 1.5), slot(0.05, 0.55, 0.9, 0.4, 1.5)], role: "cover", cover: true)
        let pages = [cover, familyA[1]]
        let pool = [photo("p0", aspect: 0.3), photo("p1", aspect: 1.5), photo("p2", aspect: 1.5)]
        let ctx = try context(pool: pool, pages: pages)
        var d = direction(momentsOf: [["p0"], ["p1", "p2"]], cover: ["p2"], title: nil)
        d.moments[1].size = "1"
        let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: pages, context: ctx, seed: 1))
        let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
        #expect(layout.slides[0].elements.first?.assetID?.rawValue == "p0")
        #expect(!Set(layout.slides.flatMap(\.elements).compactMap(\.assetID?.rawValue)).isSuperset(of: ["p1", "p2"]))
        #expect(!result.warnings.isEmpty)
    }

    private var familyA: [DesignedSet] { family("A") }
    private var familyB: [DesignedSet] { family("B") }
    private func family(_ id: String) -> [DesignedSet] {
        [page("\(id)-cover", family: id, slots: [slot(0.1, 0.2, 0.8, 0.75, 0.75)], role: "cover", cover: true,
              texts: [.init(frame: UnitRect(x: 0.1, y: 0.03, width: 0.8, height: 0.12), fontID: "InstrumentSerif-Regular", size: 40, colour: "#111111", alignment: "left", role: "title")]),
         page("\(id)-statement", family: id, slots: [slot(0, 0, 1, 1, 0.8)], role: "statement"),
         page("\(id)-wide", family: id, slots: [slot(0.05, 0.02, 0.9, 0.45, 1.6), slot(0.05, 0.53, 0.9, 0.45, 1.6)], role: "strip"),
         page("\(id)-tall", family: id, slots: (0..<3).map { slot(0.02 + Double($0) * 0.33, 0.3, 0.3, 0.4, 0.6) }, role: "strip"),
         page("\(id)-grid", family: id, slots: (0..<4).map { slot(0.02 + Double($0 % 2) * 0.5, 0.02 + Double($0 / 2) * 0.5, 0.46, 0.46, 0.8) }, role: "grid")]
    }
    private func page(_ id: String, family: String, slots: [DesignedSet.Slot], role: String, cover: Bool = false,
                      texts: [DesignedSet.TextLayer]? = nil) -> DesignedSet {
        DesignedSet(id: id, sourceRef: "test", aspect: .portrait4x5, slideCount: 1, background: "#FFFFFF", slots: slots,
                    texts: texts, family: family, sourceTemplate: id, pageIndex: 0, pageRole: role, coverCapable: cover)
    }
    private func slot(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ aspect: Double) -> DesignedSet.Slot {
        .init(frame: UnitRect(x: x, y: y, width: w, height: h), aspect: aspect, z: 0, crossesSeam: x < 1 && x + w > 1, roleHint: "hero")
    }
    private func portraits(_ n: Int) -> [PhotoRecord] { (0..<n).map { photo("p\($0)", aspect: 0.75) } }
    private func landscapes(_ n: Int) -> [PhotoRecord] { (0..<n).map { photo("l\($0)", aspect: 1.5) } }
    private func photo(_ id: String, aspect: Double) -> PhotoRecord {
        PhotoRecord(assetID: AssetID(rawValue: id), contentSHA256: id, sourceRelativePaths: ["\(id).jpg"], byteCount: 1,
                    fileType: "public.jpeg", pixelWidth: Int((aspect * 1000).rounded()), pixelHeight: 1000,
                    exifOrientation: 1, metadata: CaptureMetadata(localDateTime: "2026:05:29 10:00:00"))
    }
    private func direction(momentsOf groups: [[String]], cover: [String], title: String?) -> Direction {
        Direction(brief: "test", style: .baseline, coverAssetID: AssetID(rawValue: cover.first ?? ""), orderedAssetIDs: [],
                  moments: groups.map { .init(label: "", photos: $0.map { AssetID(rawValue: $0) }, mustInclude: [], size: $0.count == 1 ? "1" : $0.count <= 3 ? "few" : "many") },
                  coverCandidates: cover.map { AssetID(rawValue: $0) }, titleIdeas: title.map { [$0] } ?? [])
    }
    private func context(pool: [PhotoRecord], pages: [DesignedSet], exactSet: Bool = false, keepOrder: Bool = false) throws -> CompositionContext {
        CompositionContext(aspect: .portrait4x5, photos: Dictionary(uniqueKeysWithValues: pool.map { ($0.assetID, $0) }), features: [:],
                           triage: [:], flagged: [], sequenceIntent: [:], stylePack: try StylePackLoader.load(), maxSlides: nil,
                           exactSet: exactSet, keepOrder: keepOrder, pages: pages)
    }
    private func layoutContext(_ ctx: CompositionContext) -> LayoutContext {
        LayoutContext(aspect: ctx.aspect, photos: ctx.photos, features: ctx.features, stylePack: ctx.stylePack, seed: 1,
                      storyHint: ctx.storyHint, pages: ctx.pages, keepOrder: ctx.keepOrder)
    }
}
