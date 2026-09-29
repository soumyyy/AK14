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
}
