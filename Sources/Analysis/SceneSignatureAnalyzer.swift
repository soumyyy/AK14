import Core
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Lightweight local classifier used before occasion choice. It runs only Vision scene labels,
/// avoiding the full face, saliency, feature-print, and quality analysis for every imported photo.
public struct SceneSignatureAnalyzer: Sendable {
    public init() {}

    public func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures {
        var features = PhotoFeatures(assetID: record.assetID, analyzerVersion: Self.version)
        guard let source = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            features.failures[FeatureName.image.rawValue] = "thumbnail unreadable"
            return features
        }
        do {
            let observations = try await ImageRequestHandler(image).perform(ClassifyImageRequest())
            features.labels = observations.filter { $0.confidence >= 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(10).map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
        } catch {
            features.failures[FeatureName.classification.rawValue] = String(describing: error)
        }
        return features
    }

    public static let version = "scene-signature-1"
}
