import Core
import Foundation
import Render

/// Resolves and renders every concept into `<root>/layouts/<concept>/` and `<root>/slides/<concept>/`.
public enum ConceptRendering {
    public struct Result: Sendable {
        /// Concept → run-relative PNG paths, in slide order.
        public var slides: [String: [String]] = [:]
        public var warnings: [String] = []
        public var failed = false
    }

    public static func seed(runID: String, concept: String) -> UInt64 {
        ComposerEngine.layoutSeed(runID: runID, id: concept)
    }

    public static func renderAll(_ plans: [CarouselPlan], runID: String, aspect: CarouselAspect, photos: [AssetID: PhotoRecord],
                          features: [AssetID: PhotoFeatures], stylePack: StylePack, sourceFolder: URL, into root: URL,
                          seedOverride: UInt64? = nil, storyHint: String? = nil) throws -> Result {
        var result = Result()
        let store = RunStore.open(root)
        let vocabulary = (try? StylePackLoader.loadDesignedSets())?.vocabulary(for: aspect) ?? []
        for plan in plans {
            let concept = plan.id
            if !plan.isBaseline, let recipeID = plan.recipeID, let direction = plan.direction,
               let recipe = stylePack.recipes?.first(where: { $0.id == recipeID }) {
                let documentURL = store.url("documents/\(concept).json")
                let document: CanvasDocument
                if FileManager.default.fileExists(atPath: documentURL.path), let data = try? Data(contentsOf: documentURL),
                   let saved = try? JSONDecoder().decode(CanvasDocument.self, from: data) { document = saved }
                else {
                    let composition = CompositionContext(aspect: aspect, photos: photos, features: features, triage: [:],
                        flagged: [], sequenceIntent: [:], stylePack: stylePack, maxSlides: nil, storyHint: storyHint,
                        vocabulary: vocabulary)
                    document = RecipeFiller.fill(plan: plan, direction: direction, recipe: recipe, context: composition,
                                                 seed: seedOverride ?? seed(runID: runID, concept: concept))
                    try store.write(document, to: "documents/\(concept).json")
                }
                let outcome = try DocumentRenderer().render(document, photos: photos, sourceFolder: sourceFolder,
                                                            outputDirectory: store.url("slides/\(concept)"))
                result.slides[concept] = outcome.names.map { "slides/\(concept)/\($0)" }
                result.warnings += outcome.failures.map { "\(concept) render: \($0)" }
                if !outcome.failures.isEmpty { result.failed = true }
                continue
            }
            let context = LayoutContext(aspect: aspect, photos: photos, features: features, stylePack: stylePack,
                                        seed: seedOverride ?? seed(runID: runID, concept: plan.id),
                                        storyHint: storyHint,
                                        vocabulary: plan.isBaseline ? [] : vocabulary)
            let carousel = LayoutResolver.resolve(plan, context: context)
            for slide in carousel.slides {
                try store.write(slide, to: String(format: "layouts/%@/slide-%02d.json", concept, slide.index + 1))
                result.warnings += slide.warnings.map { "\(concept) slide \(slide.index + 1): \($0)" }
            }
            // Recipes only come through RecipeFiller (face-safe slots, grounded text). The internal brief is
            // operator-facing and must never be printed on a slide.
            let outcome = try CarouselRenderer().render(carousel, photos: photos, sourceFolder: sourceFolder,
                                                        outputDirectory: store.url("slides/\(concept)"))
            result.slides[concept] = outcome.names.map { "slides/\(concept)/\($0)" }
            result.warnings += outcome.failures.map { "\(concept) render: \($0)" }
            if !outcome.failures.isEmpty { result.failed = true }
        }
        return result
    }
}
