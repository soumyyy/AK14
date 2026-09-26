import Core
import Foundation

/// Rasterizes a versioned canvas document into one PNG per slide.
public struct DocumentRenderer: Sendable {
    public init() {}

    public func render(_ document: CanvasDocument, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                       outputDirectory: URL) throws -> CarouselRenderer.Outcome {
        let slides = (0..<document.slideCount).map { index in
            let elements = document.layers(onSlide: index).map { layer in
                ResolvedElement(kind: layer.kind == .photo ? .photo : layer.kind == .text ? .stamp : .tape,
                                assetID: layer.assetID, text: layer.string, frame: UnitRect(x: layer.frame.x * Double(document.slideCount) - Double(index), y: layer.frame.y, width: layer.frame.width * Double(document.slideCount), height: layer.frame.height),
                                rotationDegrees: layer.rotation, crop: layer.crop, zIndex: layer.z, opacity: layer.opacity, border: layer.border, shadow: layer.shadow, adjustments: layer.adjustments)
            }
            return ResolvedSlide(index: index, primitive: .fullBleed, requestedPrimitive: .fullBleed,
                                 background: document.slideBackgrounds[safe: index] ?? "plain",
                                 grain: document.slideGrain[safe: index] ?? 0, filmEdge: document.slideFilmEdges[safe: index] ?? false,
                                 elements: elements, warnings: [])
        }
        let carousel = ResolvedCarousel(id: document.id, aspect: document.aspect, seed: document.seed,
                                        resolverVersion: ResolvedCarousel.resolverVersion, slides: slides)
        return try CarouselRenderer().legacyRender(carousel, photos: photos, sourceFolder: sourceFolder, outputDirectory: outputDirectory)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
