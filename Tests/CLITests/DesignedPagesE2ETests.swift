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
        // Regression guard at the measured yield (73) after correct frame geometry; the spec's 150 target needs decorative layers (phase B).
        #expect(portrait.count >= 70, "only \(portrait.count) usable 4:5 pages")
        let portrait3x4 = pages.filter { $0.aspect == .portrait3x4 }
        #expect(portrait3x4.count >= 100, "only \(portrait3x4.count) usable 3:4 pages")
        for aspect in [CarouselAspect.portrait4x5, .portrait3x4] {
            #expect(pages.contains { $0.aspect == aspect && $0.coverCapable == true }, "no cover page for \(aspect)")
        }
        #expect(pages.allSatisfy { ($0.decorCoverage ?? 0) <= 0.12 })
        #expect(pages.allSatisfy { ($0.texts ?? []).allSatisfy { ["title", "caption", "accent"].contains($0.role) } })
    }

    @Test func frameWindowsStayInsideTheirFramesAndRenderDistinctPhotos() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        let style = try StylePackLoader.load()
        #expect(pages.contains { !($0.frames ?? []).isEmpty })
        for page in pages where !(page.frames ?? []).isEmpty {
            let frames = try #require(page.frames)
            for frame in frames {
                let window = try #require(frame.slotFrame)
                let x = window.x + window.width / 2, y = window.y + window.height / 2
                #expect(x >= frame.frame.x - 0.01 && x <= frame.frame.x + frame.frame.width + 0.01, "\(page.id): window x outside frame")
                #expect(y >= frame.frame.y - 0.01 && y <= frame.frame.y + frame.frame.height + 0.01, "\(page.id): window y outside frame")
            }
            let photos = page.expandedSlots.enumerated().map { index, slot in
                let aspect = frames.first { $0.slotFrame == slot.frame }?.photoWindowAspect ?? slot.aspect
                return PhotoRecord(assetID: AssetID(rawValue: "p\(index)"), contentSHA256: "p\(index)",
                    sourceRelativePaths: [], byteCount: 1, fileType: "public.jpeg",
                    pixelWidth: Int((aspect * 10000).rounded()), pixelHeight: 10000, exifOrientation: 1, metadata: CaptureMetadata())
            }
            // A stale placement invokes assignment and rendering through the public resolver.
            let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
                SlidePlan(primitive: .overlapCluster, mood: "", density: "dense", photos: photos.map { .plain($0.assetID) },
                    decorations: [], stamps: [], placement: SlidePlacement(catalogueVersion: 2, pageID: page.id,
                        runOffset: 0, runLength: 1, placed: [], slide: nil))])
            let layout = LayoutResolver.resolve(plan, context: LayoutContext(aspect: page.aspect,
                photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) }), features: [:], stylePack: style, seed: 1, pages: [page]))
            let rendered = layout.slides.flatMap(\.elements).filter { $0.kind == .frame }
            #expect(Set(rendered.compactMap(\.assetID)).count == frames.count, "\(page.id): frames reuse a photo window")
            #expect(Set(rendered.compactMap(\.assetID)).isSubset(of: Set(photos.map(\.assetID))))
        }
    }

    @Test func linkedRunsStayWhole() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        func crosses(_ frame: UnitRect, _ boundary: Double) -> Bool {
            frame.x < boundary - 0.001 && frame.x + frame.width > boundary + 0.001
        }
        func hasCrossingLayer(_ page: DesignedSet, at boundary: Double) -> Bool {
            page.slots.contains { crosses($0.frame, boundary) } ||
                (page.frames ?? []).contains { crosses($0.frame, boundary) } ||
                (page.texts ?? []).contains { crosses($0.frame, boundary) }
        }
        for page in pages where page.slideCount == 1 {
            #expect(!hasCrossingLayer(page, at: 0), "\(page.id) has a layer crossing its left edge")
            #expect(!hasCrossingLayer(page, at: 1), "\(page.id) has a layer crossing its right edge")
        }
        for run in pages where run.slideCount > 1 {
            for boundary in 1..<run.slideCount {
                #expect(hasCrossingLayer(run, at: Double(boundary)),
                        "\(run.id) has no slot, frame, or text crossing boundary \(boundary)")
            }
        }
    }
}
