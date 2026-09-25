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
}
