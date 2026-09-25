import Foundation

public struct StageTiming: Codable, Sendable, Equatable {
    public let stage: String
    public let seconds: Double
    public init(stage: String, seconds: Double) { self.stage = stage; self.seconds = seconds }
}

public struct RunManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = RunManifest.currentSchemaVersion
    public let runID: String
    public let createdAt: Date
    public var completedAt: Date?
    /// Last path component of the input folder only; never an absolute path.
    public let sourceFolderLabel: String
    /// SHA-256 over the sorted content digests of all ingested photos.
    public var inputDigest: String = ""
    public var photoCount: Int = 0
    public var skippedCount: Int = 0
    public var aspectRatio: CarouselAspect = .portrait4x5
    public var aspectOverridden: Bool = false
    /// Component name -> version, e.g. "analyzer": "vision-1".
    public var versions: [String: String] = [:]
    public var stageTimings: [StageTiming] = []
    public var cacheHits: Int = 0
    public var cacheMisses: Int = 0
    public var warnings: [String] = []

    public init(runID: String, createdAt: Date, sourceFolderLabel: String) {
        self.runID = runID; self.createdAt = createdAt; self.sourceFolderLabel = sourceFolderLabel
    }
}
