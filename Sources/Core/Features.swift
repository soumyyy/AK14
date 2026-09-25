import Foundation

/// Normalized rectangle with a TOP-LEFT origin (converted from Vision's bottom-left origin).
public struct UnitRect: Codable, Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct FaceRegion: Codable, Sendable, Equatable {
    public let box: UnitRect
    public let captureQuality: Double?
    public init(box: UnitRect, captureQuality: Double?) { self.box = box; self.captureQuality = captureQuality }
}

public struct SceneLabel: Codable, Sendable, Equatable {
    public let identifier: String
    public let confidence: Double
    public init(identifier: String, confidence: Double) { self.identifier = identifier; self.confidence = confidence }
}

public enum FeatureName: String, Codable, Sendable, CaseIterable {
    case image, featurePrint, aesthetics, faces, humans, saliency, classification, luminance
}

public struct PhotoFeatures: Codable, Sendable, Equatable {
    public let assetID: AssetID
    public let analyzerVersion: String
    public var aestheticScore: Double?
    public var isUtility: Bool?
    public var faces: [FaceRegion] = []
    public var humans: [UnitRect] = []
    public var salientRegions: [UnitRect] = []
    /// Confidence >= 0.3, at most 10, sorted by confidence descending.
    public var labels: [SceneLabel] = []
    public var meanLuminance: Double?
    /// Fraction of pixels with luma < 0.06.
    public var darkFraction: Double?
    /// Laplacian variance on a 256 px gray downsample, /1000, clamped 0...1. Low = blurry.
    public var sharpness: Double?
    /// Path relative to the cache root.
    public var featurePrintFile: String?
    /// FeatureName.rawValue -> error description. Empty means complete.
    public var failures: [String: String] = [:]

    public init(assetID: AssetID, analyzerVersion: String) {
        self.assetID = assetID; self.analyzerVersion = analyzerVersion
    }
}
