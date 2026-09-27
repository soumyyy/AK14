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
                          seedOverride: UInt64? = nil) throws -> Result {
        var result = Result()
        let store = RunStore.open(root)
        for plan in plans {
            let concept = plan.id
            let context = LayoutContext(aspect: aspect, photos: photos, features: features, stylePack: stylePack,
                                        seed: seedOverride ?? seed(runID: runID, concept: plan.id))
            let carousel = LayoutResolver.resolve(plan, context: context)
            for slide in carousel.slides {
                try store.write(slide, to: String(format: "layouts/%@/slide-%02d.json", concept, slide.index + 1))
                result.warnings += slide.warnings.map { "\(concept) slide \(slide.index + 1): \($0)" }
            }
            let outcome = try CarouselRenderer().render(carousel, photos: photos, sourceFolder: sourceFolder,
                                                        outputDirectory: store.url("slides/\(concept)"))  // recipes only via RecipeFiller documents; never print the internal brief
            result.slides[concept] = outcome.names.map { "slides/\(concept)/\($0)" }
            result.warnings += outcome.failures.map { "\(concept) render: \($0)" }
            if !outcome.failures.isEmpty { result.failed = true }
        }
        return result
    }
}
