import Core
import Foundation
import Render
import Testing

@Suite struct PlacementE2ETests {
    @Test func storedPlacementReplaysExactlyAndFixesSlideIndices() throws {
        let page = pageSet("p", slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])
        let a = photo("a", aspect: 0.8), b = photo("b", aspect: 0.8)
        let ctx = try context(photos: [a, b], vocabulary: [], pages: [page])
        var plan = planWithPlacements(page: page, photos: [a, b], context: ctx)
        let first = LayoutResolver.resolve(plan, context: ctx)
        #expect(first.slides.map(\.variant) == ["template.p", "template.p"])
        plan = try PlanEditor.apply(.reorder(from: 1, to: 0), to: plan)
        let reordered = LayoutResolver.resolve(plan, context: ctx)
        #expect(reordered.slides.map(\.index) == [0, 1])
        #expect(reordered.slides[0].elements.first { $0.kind == .photo }?.assetID == b.assetID)
    }

    @Test func swappingInAPhotoThatDoesNotFitFallsBackWithoutLosingIt() throws {
        let page = pageSet("wide-only", slots: [slot(x: 0, y: 0.3, w: 1, h: 0.4, aspect: 2.0, z: 0)])
        let wide = photo("wide", aspect: 2.0), tall = photo("tall", aspect: 0.5)
        let ctx = try context(photos: [wide, tall], vocabulary: [], pages: [page])
        var plan = planWithPlacements(page: page, photos: [wide], context: ctx)
        plan = try PlanEditor.apply(.swap(slide: 0, photo: wide.assetID, with: tall.assetID), to: plan)
        #expect(plan.slides[0].placement?.slide == nil)
        let resolved = LayoutResolver.resolve(plan, context: ctx)
        #expect(resolved.slides[0].elements.contains { $0.assetID == tall.assetID })
        #expect(resolved.slides[0].variant != "template.wide-only")
    }

    @Test func plansWithoutPlacementRenderTheSameAsBefore() throws {
        let a = photo("a", aspect: 0.8)
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(a.assetID)], decorations: [], stamps: [])])
        let json = try JSONEncoder().encode(plan)
        #expect(!String(decoding: json, as: UTF8.self).contains("placement"))
        let decoded = try JSONDecoder().decode(CarouselPlan.self, from: json)
        let without = LayoutResolver.resolve(decoded, context: try context(photos: [a], vocabulary: [], pages: []))
        let with = LayoutResolver.resolve(decoded, context: try context(photos: [a], vocabulary: [], pages: [pageSet("x", slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])]))
        #expect(without.slides == with.slides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(without.slides) == encoder.encode(with.slides))
    }

    @Test func documentKeepsTextRoleAndLineCount() throws {
        let slide = ResolvedSlide(index: 0, primitive: .hero, requestedPrimitive: .hero, background: "plain", grain: 0, filmEdge: false,
            elements: [ResolvedElement(kind: .text, assetID: nil, text: "Days in the mist", frame: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1),
                                       rotationDegrees: 0, crop: nil, zIndex: 5, opacity: 1, border: 0, shadow: false,
                                       fontID: "InstrumentSerif-Regular", fontSize: 40, numberOfLines: 2, textRole: "title")], warnings: [])
        let doc = CanvasDocument(from: ResolvedCarousel(id: "c1", aspect: .portrait4x5, seed: "1", resolverVersion: "layout-3", slides: [slide]), photos: [:])
        let layer = try #require(doc.layers.first { $0.kind == .text })
        #expect(layer.textRole == "title")
        #expect(layer.lineCount == 2)
    }

    private func planWithPlacements(page: DesignedSet, photos: [PhotoRecord], context: LayoutContext) -> CarouselPlan {
        var title = false, captions = 0
        let base = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [])
        let slides = photos.enumerated().map { i, p -> SlidePlan in
            let placed = SlotAssignment.assign([p.assetID], to: page, hero: p.assetID, keepOrder: false,
                                               records: context.photos, features: context.features)!.placed
            let resolved = TemplateVocabulary.render(page: page, placed: placed, plan: base, start: i, context: context,
                                                     titlePlaced: &title, captionCount: &captions)[0]
            var s = SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(p.assetID)], decorations: [], stamps: [])
            s.placement = SlidePlacement(catalogueVersion: 2, pageID: page.id, runOffset: 0, runLength: 1, placed: placed, slide: resolved)
            return s
        }
        return CarouselPlan(id: "c1", brief: "", direction: nil, slides: slides)
    }

    private func pageSet(_ id: String, slots: [DesignedSet.Slot]) -> DesignedSet {
        DesignedSet(id: id, sourceRef: "test", aspect: .portrait4x5, slideCount: 1, background: "#FFFFFF", slots: slots,
                    sourceTemplate: "t", pageIndex: 0, pageRole: "statement", coverCapable: true)
    }

    private func context(photos: [PhotoRecord], features: [AssetID: PhotoFeatures] = [:], vocabulary: [DesignedSet],
                         pages: [DesignedSet] = [], seed: UInt64 = 1, keepOrder: Bool = false) throws -> LayoutContext {
        LayoutContext(aspect: .portrait4x5, photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) }),
                      features: features, stylePack: try StylePackLoader.load(), seed: seed, vocabulary: vocabulary,
                      pages: pages, keepOrder: keepOrder)
    }

    private func photo(_ id: String, aspect: Double) -> PhotoRecord {
        let asset = AssetID(rawValue: id)
        return PhotoRecord(assetID: asset, contentSHA256: id, sourceRelativePaths: ["\(id).jpg"], byteCount: 1,
                           fileType: "public.jpeg", pixelWidth: max(1, Int((aspect * 1000).rounded())), pixelHeight: 1000,
                           exifOrientation: 1, metadata: CaptureMetadata(localDateTime: "2026:05:29 10:00:00"))
    }

    private func set(_ id: String, slides: Int, aspect: CarouselAspect = .portrait4x5, slots: [DesignedSet.Slot]) -> DesignedSet {
        DesignedSet(id: id, sourceRef: "test", aspect: aspect, slideCount: slides, background: "#FFFFFF", slots: slots)
    }

    private func slot(x: Double, y: Double, w: Double, h: Double, aspect: Double, z: Int, role: String = "hero", crosses: Bool = false) -> DesignedSet.Slot {
        DesignedSet.Slot(frame: UnitRect(x: x, y: y, width: w, height: h), aspect: aspect, z: z,
                         crossesSeam: crosses, roleHint: role)
    }
}
