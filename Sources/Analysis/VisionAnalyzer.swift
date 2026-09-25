import Core
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts local features from an analysis-tier thumbnail. Each Vision request is isolated:
/// a failure is recorded in `failures` and the remaining features are still produced.
public struct VisionAnalyzer: PhotoAnalyzing {
    public static let version = "vision-2"
    public let cacheRoot: URL

    public init(cacheRoot: URL) { self.cacheRoot = cacheRoot }

    public func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures {
        var f = PhotoFeatures(assetID: record.assetID, analyzerVersion: Self.version)
        guard let src = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            f.failures[FeatureName.image.rawValue] = "thumbnail unreadable"
            return f
        }
        let handler = ImageRequestHandler(image)

        do {
            let featurePrint = try await handler.perform(GenerateImageFeaturePrintRequest())
            let rel = "featureprints/\(Self.version)/\(record.contentSHA256).json"
            let target = cacheRoot.appending(path: rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(featurePrint).write(to: target, options: .atomic)
            f.featurePrintFile = rel
        } catch { f.failures[FeatureName.featurePrint.rawValue] = "\(error)" }

        do {
            let a = try await handler.perform(CalculateImageAestheticsScoresRequest())
            f.aestheticScore = Double(a.overallScore)
            f.isUtility = a.isUtility
        } catch { f.failures[FeatureName.aesthetics.rawValue] = "\(error)" }

        do {
            let faces = try await handler.perform(DetectFaceCaptureQualityRequest())
            f.faces = faces.map {
                FaceRegion(box: UnitRect(visionRect: $0.boundingBox.cgRect),
                           captureQuality: $0.captureQuality.map { Double($0.score) })
            }
        } catch { f.failures[FeatureName.faces.rawValue] = "\(error)" }

        do {
            let humans = try await handler.perform(DetectHumanRectanglesRequest())
            f.humans = humans.map { UnitRect(visionRect: $0.boundingBox.cgRect) }
        } catch { f.failures[FeatureName.humans.rawValue] = "\(error)" }

        do {
            let saliency = try await handler.perform(GenerateAttentionBasedSaliencyImageRequest())
            f.salientRegions = saliency.salientObjects.map { UnitRect(visionRect: $0.boundingBox.cgRect) }
        } catch { f.failures[FeatureName.saliency.rawValue] = "\(error)" }

        do {
            let labels = try await handler.perform(ClassifyImageRequest())
            f.labels = labels
                .filter { $0.confidence >= 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(10)
                .map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
        } catch { f.failures[FeatureName.classification.rawValue] = "\(error)" }

        if let stats = ImageStats.luminance(of: image), let sharpness = ImageStats.sharpness(of: image) {
            f.meanLuminance = stats.mean
            f.darkFraction = stats.darkFraction
            f.sharpness = sharpness
        } else {
            f.failures[FeatureName.luminance.rawValue] = "could not draw image"
        }
        return f
    }
}
