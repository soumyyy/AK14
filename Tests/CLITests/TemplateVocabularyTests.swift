import Core
import Render
import Testing

@Suite struct TemplateVocabularyTests {
    @Test func vocabularyKeepsEverySetOfTheCarouselAspect() {
        let large = set("large", slides: 1, slots: [slot(x: 0, y: 0, w: 0.7, h: 0.9, aspect: 0.62, z: 1)])
        let small = set("small", slides: 1, slots: [slot(x: 0.1, y: 0.1, w: 0.4, h: 0.4, aspect: 0.8, z: 1)])
        let long = set("long", slides: 4, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 1)])
        let square = set("square", slides: 1, aspect: .square, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 1, z: 1)])
        let library = DesignedSetLibrary(frameInference: "test", sets: [large, small, long, square])
        #expect(library.vocabulary(for: .portrait4x5).map(\.id) == ["large", "small", "long"])
        #expect(library.vocabulary(for: .square).map(\.id) == ["square"])
    }

    @Test func heroGoesInTheLargestSlotAndTheChoiceRepeats() throws {
        let arrangement = set("pair", slides: 1, slots: [
            slot(x: 0, y: 0, w: 0.62, h: 1, aspect: 0.5, z: 1, role: "hero"),
            slot(x: 0.66, y: 0.55, w: 0.3, h: 0.35, aspect: 0.7, z: 0, role: "support")
        ])
        let support = photo("support", aspect: 0.7)
        let hero = photo("hero", aspect: 0.5)
        var supportElement = PhotoElement.plain(support.assetID)
        supportElement.role = "support"
        var heroElement = PhotoElement.plain(hero.assetID)
        heroElement.role = "hero"
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .asymmetricPair, mood: "", density: "balanced", photos: [supportElement, heroElement],
                      decorations: [], stamps: [])
        ])
        let first = LayoutResolver.resolve(plan, context: try context(photos: [support, hero], vocabulary: [arrangement], seed: 9))
        let again = LayoutResolver.resolve(plan, context: try context(photos: [support, hero], vocabulary: [arrangement], seed: 9))
        #expect(first == again)
        #expect(first.slides[0].variant == "template.pair")
        #expect(first.slides[0].background == arrangement.background)
        let frames = Dictionary(uniqueKeysWithValues: first.slides[0].elements.compactMap { element in
            element.assetID.map { ($0, element.frame) }
        })
        #expect(abs((frames[hero.assetID]?.width ?? 0) - 0.62) < 0.001)
        #expect(abs((frames[support.assetID]?.width ?? 0) - 0.3) < 0.001)
    }

    @Test func heroLabelDoesNotExcludeBalancedPairOrGathering() throws {
        let balancedPair = set("balanced-pair", slides: 1, slots: [
            slot(x: 0, y: 0, w: 0.48, h: 0.8, aspect: 0.6, z: 1),
            slot(x: 0.52, y: 0.1, w: 0.46, h: 0.7, aspect: 0.66, z: 0)
        ])
        let one = photo("pair-one", aspect: 0.6), two = photo("pair-two", aspect: 0.66)
        var hero = PhotoElement.plain(one.assetID); hero.role = "hero"
        var support = PhotoElement.plain(two.assetID); support.role = "support"
        let direction = Direction(brief: "balanced", style: StyleVector(density: "balanced", overlap: "none",
            grouping: "mixed", decoration: "none", rotation: "none", whitespace: "tight"),
            coverAssetID: one.assetID, orderedAssetIDs: [one.assetID, two.assetID])
        let plan = CarouselPlan(id: "c1", brief: "", direction: direction, slides: [
            SlidePlan(primitive: .asymmetricPair, mood: "", density: "balanced", photos: [hero, support], decorations: [], stamps: [])
        ])
        let resolved = LayoutResolver.resolve(plan, context: try context(photos: [one, two], vocabulary: [balancedPair]))
        #expect(resolved.slides[0].variant == "template.balanced-pair")
    }

    @Test func composerKeepsSupportedGroupingAndScoresWithTheSameVocabulary() throws {
        let pairSet = set("composer-pair", slides: 1, slots: [
            slot(x: 0, y: 0, w: 0.48, h: 0.8, aspect: 0.6, z: 1),
            slot(x: 0.52, y: 0.1, w: 0.46, h: 0.7, aspect: 0.66, z: 0)
        ])
        let first = photo("compose-one", aspect: 0.6), second = photo("compose-two", aspect: 0.66)
        let direction = Direction(brief: "together", style: StyleVector(density: "balanced", overlap: "none",
            grouping: "mixed", decoration: "none", rotation: "none", whitespace: "tight"),
            coverAssetID: first.assetID, orderedAssetIDs: [first.assetID, second.assetID],
            keepTogether: [[first.assetID, second.assetID]])
        let composition = CompositionContext(aspect: .portrait4x5,
            photos: [first.assetID: first, second.assetID: second], features: [:], triage: [:], flagged: [],
            sequenceIntent: [:], stylePack: try StylePackLoader.load(), maxSlides: 1, exactSet: true,
            vocabulary: [pairSet])
        let result = ComposerEngine.compose(direction, id: "c1", context: composition, seed: 19)
        #expect(result.plan.slides.first?.photos.count == 2)
        #expect(result.plan.recipeID == nil, "a selected vocabulary template must remain the final render path")
        let layout = LayoutResolver.resolve(result.plan, context: try context(photos: [first, second], vocabulary: [pairSet]))
        #expect(layout.slides.first?.variant == "template.composer-pair")
    }

    @Test func unsafeCropAndBaselineStayOnThePrimitivePath() throws {
        let wide = set("wide", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 0.7, aspect: 3, z: 1)])
        let square = photo("square", aspect: 1)
        let element = PhotoElement.plain(square.assetID)
        let slide = SlidePlan(primitive: .fullBleed, mood: "", density: "balanced", photos: [element], decorations: [], stamps: [])
        let creative = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [slide])
        let rejected = LayoutResolver.resolve(creative, context: try context(photos: [square], vocabulary: [wide]))
        #expect(rejected.slides[0].variant?.hasPrefix("template.") != true)

        let fitting = set("full", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 1, z: 1)])
        let baseline = CarouselPlan(id: CarouselPlan.baselineID, brief: "", direction: nil, slides: [slide])
        let control = LayoutResolver.resolve(baseline, context: try context(photos: [square], vocabulary: [fitting]))
        #expect(control.slides[0].variant?.hasPrefix("template.") != true)
    }

    @Test func seamSetSlicesTheCrossingPhotoAndRejectsAPersonOnTheEdge() throws {
        let crossing = set("seam", slides: 2, slots: [
            slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 1, role: "hero"),
            slot(x: 0.6, y: 0.2, w: 0.8, h: 0.5, aspect: 1.6, z: 0, role: "support", crosses: true)
        ])
        let hero = photo("hero", aspect: 0.8)
        let side = photo("side", aspect: 1.6)
        var heroElement = PhotoElement.plain(hero.assetID)
        heroElement.role = "hero"
        var sideElement = PhotoElement.plain(side.assetID)
        sideElement.role = "support"
        let slides = [heroElement, sideElement].map {
            SlidePlan(primitive: .fullBleed, mood: "", density: "balanced", photos: [$0], decorations: [], stamps: [])
        }
        let direction = Direction(brief: "continue", style: .baseline, coverAssetID: hero.assetID,
                                  orderedAssetIDs: [hero.assetID, side.assetID], seamless: true)
        let plan = CarouselPlan(id: "c1", brief: "", direction: direction, slides: slides)
        let placed = LayoutResolver.resolve(plan, context: try context(photos: [hero, side], vocabulary: [crossing], seed: 3))
        #expect(placed.slides.map(\.variant) == ["template.seam", "template.seam"])
        let piece = try #require(placed.slides[1].elements.first { $0.assetID == side.assetID })
        #expect(abs(piece.frame.x - 0) < 0.001)
        #expect(abs(piece.frame.width - 0.4) < 0.001)
        #expect(abs((piece.crop?.x ?? -1) - 0.5) < 0.001)
        #expect(abs((piece.crop?.width ?? -1) - 0.5) < 0.001)

        var features = PhotoFeatures(assetID: side.assetID, analyzerVersion: "test")
        features.humans = [UnitRect(x: 0.35, y: 0.2, width: 0.4, height: 0.5)]
        let blocked = LayoutResolver.resolve(plan, context: try context(photos: [hero, side], features: [side.assetID: features], vocabulary: [crossing]))
        #expect(blocked.slides.allSatisfy { $0.variant?.hasPrefix("template.") != true })
    }

    @Test func widePhotoDoesNotImplySeamlessDirection() throws {
        let crossing = set("seam", slides: 2, slots: [
            slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 1),
            slot(x: 0.6, y: 0.2, w: 0.8, h: 0.5, aspect: 1.6, z: 0, crosses: true)
        ])
        let hero = photo("hero", aspect: 0.8), wide = photo("wide", aspect: 2.4)
        let elements = [PhotoElement.plain(hero.assetID), PhotoElement.plain(wide.assetID)]
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: elements.map {
            SlidePlan(primitive: .fullBleed, mood: "", density: "balanced", photos: [$0], decorations: [], stamps: [])
        })
        let resolved = LayoutResolver.resolve(plan, context: try context(photos: [hero, wide], vocabulary: [crossing]))
        #expect(resolved.slides.allSatisfy { $0.variant != "template.seam" })
    }

    @Test func onePhotoUsesTheStatementLayoutAndIgnoresTheSeed() throws {
        let quiet = set("alpha", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])
        let seam = set("beta", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0, crosses: true)])
        let image = photo("one", aspect: 0.8)
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .fullBleed, mood: "", density: "balanced", photos: [PhotoElement.plain(image.assetID)],
                      decorations: [], stamps: [])
        ])
        for seed in UInt64(0)..<8 {
            let resolved = LayoutResolver.resolve(plan, context: try context(photos: [image], vocabulary: [quiet, seam], seed: seed))
            #expect(resolved.slides[0].variant == "template.alpha")
        }
    }

    @Test func equallyFittingTemplatesVaryBySeedAndRepeatDeterministically() throws {
        let templates = [
            set("alpha", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)]),
            set("beta", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)]),
            set("gamma", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])
        ]
        let image = photo("seeded", aspect: 0.8)
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .fullBleed, mood: "", density: "balanced",
                      photos: [PhotoElement.plain(image.assetID)], decorations: [], stamps: [])
        ])

        let resolved = (0..<8).map { seed in
            LayoutResolver.resolve(plan, context: try! context(photos: [image], vocabulary: templates, seed: UInt64(seed)))
        }
        let repeated = (0..<8).map { seed in
            LayoutResolver.resolve(plan, context: try! context(photos: [image], vocabulary: templates, seed: UInt64(seed)))
        }

        #expect(resolved == repeated)
        #expect(Set(resolved.compactMap(\.slides.first?.variant)).count >= 2)
    }

    @Test func carouselPrefersUnusedEquallyFittingTemplates() throws {
        let templates = [
            set("alpha", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)]),
            set("beta", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)]),
            set("gamma", slides: 1, slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])
        ]
        let images = [photo("one", aspect: 0.8), photo("two", aspect: 0.8), photo("three", aspect: 0.8)]
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: images.map { image in
            SlidePlan(primitive: .fullBleed, mood: "", density: "balanced",
                      photos: [PhotoElement.plain(image.assetID)], decorations: [], stamps: [])
        })

        let resolved = LayoutResolver.resolve(plan, context: try context(photos: images, vocabulary: templates, seed: 7))
        let variants = resolved.slides.compactMap(\.variant)

        #expect(variants.count == 3)
        #expect(Set(variants).count == 3)
    }

    private func context(photos: [PhotoRecord], features: [AssetID: PhotoFeatures] = [:], vocabulary: [DesignedSet], seed: UInt64 = 1) throws -> LayoutContext {
        LayoutContext(aspect: .portrait4x5, photos: Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) }),
                      features: features, stylePack: try StylePackLoader.load(), seed: seed, vocabulary: vocabulary)
    }

    private func photo(_ id: String, aspect: Double) -> PhotoRecord {
        let asset = AssetID(rawValue: id)
        return PhotoRecord(assetID: asset, contentSHA256: id, sourceRelativePaths: ["\(id).jpg"], byteCount: 1,
                           fileType: "public.jpeg", pixelWidth: max(1, Int((aspect * 1000).rounded())), pixelHeight: 1000,
                           exifOrientation: 1, metadata: CaptureMetadata())
    }

    private func set(_ id: String, slides: Int, aspect: CarouselAspect = .portrait4x5, slots: [DesignedSet.Slot]) -> DesignedSet {
        DesignedSet(id: id, sourceRef: "test", aspect: aspect, slideCount: slides, background: "#FFFFFF", slots: slots)
    }

    private func slot(x: Double, y: Double, w: Double, h: Double, aspect: Double, z: Int, role: String = "hero", crosses: Bool = false) -> DesignedSet.Slot {
        DesignedSet.Slot(frame: UnitRect(x: x, y: y, width: w, height: h), aspect: aspect, z: z,
                         crossesSeam: crosses, roleHint: role)
    }
}
