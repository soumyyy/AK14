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
    public var funnel: Funnel?
    /// "ok", "fallback", "failed: …", or "skipped: …". nil before M3 stages run.
    public var directorStatus: String?
    public var providerCalls: [ProviderCallRecord] = []
    public var totalEstimatedCost: Double = 0
    /// Pseudonymous participant code (never a name).
    public var studyCode: String?
    /// Set when the participant/operator acknowledged the provider disclosure.
    public var consent: Consent?
    public var events: [EventSegmentSummary] = []
    public var chosenEvent: Int?
    public var storyHint: String?
    public var exactSet: Bool = false

    public init(runID: String, createdAt: Date, sourceFolderLabel: String) {
        self.runID = runID; self.createdAt = createdAt; self.sourceFolderLabel = sourceFolderLabel
    }

    /// Tolerates manifests written by older versions: every field added after M1 is optional on read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        runID = try c.decode(String.self, forKey: .runID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        sourceFolderLabel = try c.decode(String.self, forKey: .sourceFolderLabel)
        inputDigest = try c.decodeIfPresent(String.self, forKey: .inputDigest) ?? ""
        photoCount = try c.decodeIfPresent(Int.self, forKey: .photoCount) ?? 0
        skippedCount = try c.decodeIfPresent(Int.self, forKey: .skippedCount) ?? 0
        aspectRatio = try c.decodeIfPresent(CarouselAspect.self, forKey: .aspectRatio) ?? .portrait4x5
        aspectOverridden = try c.decodeIfPresent(Bool.self, forKey: .aspectOverridden) ?? false
        versions = try c.decodeIfPresent([String: String].self, forKey: .versions) ?? [:]
        stageTimings = try c.decodeIfPresent([StageTiming].self, forKey: .stageTimings) ?? []
        cacheHits = try c.decodeIfPresent(Int.self, forKey: .cacheHits) ?? 0
        cacheMisses = try c.decodeIfPresent(Int.self, forKey: .cacheMisses) ?? 0
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        funnel = try c.decodeIfPresent(Funnel.self, forKey: .funnel)
        directorStatus = try c.decodeIfPresent(String.self, forKey: .directorStatus)
        providerCalls = try c.decodeIfPresent([ProviderCallRecord].self, forKey: .providerCalls) ?? []
        totalEstimatedCost = try c.decodeIfPresent(Double.self, forKey: .totalEstimatedCost) ?? 0
        studyCode = try c.decodeIfPresent(String.self, forKey: .studyCode)
        consent = try c.decodeIfPresent(Consent.self, forKey: .consent)
        events = try c.decodeIfPresent([EventSegmentSummary].self, forKey: .events) ?? []
        chosenEvent = try c.decodeIfPresent(Int.self, forKey: .chosenEvent)
        storyHint = try c.decodeIfPresent(String.self, forKey: .storyHint)
        exactSet = try c.decodeIfPresent(Bool.self, forKey: .exactSet) ?? false
    }
}

public struct EventSegmentSummary: Codable, Sendable, Equatable {
    public let index: Int
    public let start: Date?
    public let end: Date?
    public let photoCount: Int
    public init(_ segment: EventSegment) {
        index = segment.index; start = segment.start; end = segment.end; photoCount = segment.photoCount
    }
}
