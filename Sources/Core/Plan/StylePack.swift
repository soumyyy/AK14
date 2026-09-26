import Foundation

public struct StylePack: Codable, Sendable, Equatable {
    public var id: String
    public var version: String
    public var active: Bool
    public var minAppVersion: String
    public var primitiveWeights: [String: Double]
    public var decorationIDs: [String]
    public var fontIDs: [String]
    public var textureIDs: [String]
    public var allowedRotations: [String: Double]
    public var overlapRanges: [String: Double]
    public var spacingRanges: [String: Double]
    public var densityProfile: [String]
    public var promptHints: [String]
    public var explorationWeight: Double
    public var constitution: String?
    public var referenceImages: [ReferenceImage]?
    public var trendNotes: [String]?
    public var judge: JudgeConfig?
    public var recipes: [Recipe]?
}

public struct ReferenceImage: Codable, Sendable, Equatable {
    public var id: String
    public var sha256: String
    public var tags: [String]
}

public struct JudgeConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var candidates: Int
    public var model: String?
}
