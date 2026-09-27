import Foundation
import Testing
@testable import Core
@testable import Render

@Test func recipeSelectionKeepsBaselineOutAndRichStyleChoosesDecorativeFamily() throws {
    let pack = try StylePackLoader.load()
    let recipes = try #require(pack.recipes)
    let rich = StyleVector(density: "balanced", overlap: "some", grouping: "collage", decoration: "rich", rotation: "some", whitespace: "airy")
    let selected = try #require(RecipeFiller.select(for: rich, recipes: recipes, seed: 7))
    #expect(selected.family == .scrapbook || selected.family == .journal)
    #expect(RecipeFiller.select(for: .baseline, recipes: recipes, seed: 7) == nil)
}

@Test func directionRecipeFieldsRoundTripWithLengthLimit() throws {
    let id = AssetID(rawValue: "photo")
    let direction = Direction(brief: "", style: .baseline, coverAssetID: id, orderedAssetIDs: [id],
                              seamless: true, titleIdea: String(repeating: "a", count: 55))
    #expect(direction.titleIdea?.count == 40)
    let decoded = try JSONDecoder().decode(Direction.self, from: JSONEncoder().encode(direction))
    #expect(decoded == direction)
}

@Test func fillerBuildsSafePhotoDocumentWithGroundedTitle() throws {
    let pack = try StylePackLoader.load()
    let recipe = try #require(pack.recipes?.first { $0.family == .scrapbook })
    let id = AssetID(rawValue: "photo")
    let photo = PhotoRecord(assetID: id, contentSHA256: "0", sourceRelativePaths: ["photo.jpg"], byteCount: 1,
                            fileType: "public.jpeg", pixelWidth: 1200, pixelHeight: 1600, exifOrientation: 1,
                            metadata: CaptureMetadata(capturedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    let features = PhotoFeatures(assetID: id, analyzerVersion: "test")
    let style = StyleVector(density: "balanced", overlap: "some", grouping: "mixed", decoration: "rich", rotation: "some", whitespace: "airy")
    let direction = Direction(brief: "", style: style, coverAssetID: id, orderedAssetIDs: [id], titleIdea: "A quiet afternoon")
    let slide = SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(id)], decorations: [], stamps: [])
    let plan = CarouselPlan(id: "c1", brief: "", direction: direction, slides: [slide])
    let context = CompositionContext(aspect: .portrait4x5, photos: [id: photo], features: [id: features], triage: [:],
                                     flagged: [], sequenceIntent: [:], stylePack: pack, maxSlides: nil)
    let document = RecipeFiller.fill(plan: plan, direction: direction, recipe: recipe, context: context, seed: 42)
    #expect(document.recipeID == recipe.id)
    #expect(document.layers.contains { $0.kind == .photo && $0.assetID == id && CropPlanner.facesFit(features, crop: $0.crop!) })
    #expect(document.layers.contains { $0.kind == .text && $0.string == "A quiet afternoon" })
    #expect(document.layers.filter { $0.kind == .sticker }.allSatisfy { sticker in
        !document.layers.contains { $0.kind == .photo && $0.frame.x < sticker.frame.x + sticker.frame.width
            && sticker.frame.x < $0.frame.x + $0.frame.width && $0.frame.y < sticker.frame.y + sticker.frame.height
            && sticker.frame.y < $0.frame.y + $0.frame.height }
    })
}
