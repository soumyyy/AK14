import Core
import Foundation
import Render
import Testing

@Suite struct DesignedPagesE2ETests {
    @Test func pageLibraryLoadsAndOldSetsStillDecode() throws {
        let pages = try StylePackLoader.loadDesignedPages()
        #expect(pages.validationError() == nil)
        #expect(pages.sets.allSatisfy { $0.isPage })
        let sets = try StylePackLoader.loadDesignedSets()
        #expect(sets.validationError() == nil)
        #expect(sets.sets.allSatisfy { !$0.isPage })
    }

    @Test func pageFieldsRoundTripAndShapeClassesMatchTheSpec() throws {
        let page = DesignedSet(id: "17v28-t1-p0", sourceRef: "17v28:template-1", aspect: .portrait4x5, slideCount: 1,
                               background: "#FFFFFF",
                               slots: [DesignedSet.Slot(frame: UnitRect(x: 0, y: 0, width: 1, height: 1), aspect: 0.8, z: 0,
                                                        crossesSeam: false, roleHint: "hero")],
                               sourceTemplate: "template-1", pageIndex: 0, pageRole: "statement", coverCapable: true)
        let decoded = try JSONDecoder().decode(DesignedSet.self, from: JSONEncoder().encode(page))
        #expect(decoded == page)
        #expect(decoded.validationError() == nil)
        #expect(ShapeClass.of(aspect: 0.75) == .tall)
        #expect(ShapeClass.of(aspect: 1.0) == .square)
        #expect(ShapeClass.of(aspect: 1.5) == .wide)
        #expect(ShapeClass.of(aspect: 2.4) == .band)
    }

    @Test func catalogueHasEnoughUsablePagesAndNoSampleText() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        let portrait = pages.filter { $0.aspect == .portrait4x5 }
        #expect(portrait.count >= 150, "only \(portrait.count) usable 4:5 pages")
        let portrait3x4 = pages.filter { $0.aspect == .portrait3x4 }
        #expect(portrait3x4.count >= 100, "only \(portrait3x4.count) usable 3:4 pages")
        for aspect in [CarouselAspect.portrait4x5, .portrait3x4] {
            #expect(pages.contains { $0.aspect == aspect && $0.coverCapable == true }, "no cover page for \(aspect)")
        }
        #expect(pages.allSatisfy { ($0.decorCoverage ?? 0) <= 0.12 })
        #expect(pages.allSatisfy { ($0.texts ?? []).allSatisfy { ["title", "caption", "accent"].contains($0.role) } })
    }

    @Test func linkedRunsStayWhole() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        for page in pages where page.slideCount == 1 {
            #expect(!page.crossesSeam, "\(page.id) is a single page with a slot crossing its edge")
        }
        for run in pages where run.slideCount > 1 {
            #expect(run.crossesSeam || (run.frames ?? []).contains { $0.frame.x.rounded(.down) != ($0.frame.x + $0.frame.width).rounded(.down) },
                    "\(run.id) is a run but nothing links its pages")
        }
    }
}
