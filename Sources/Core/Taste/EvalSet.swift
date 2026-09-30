import Foundation

public struct CandidateRef: Codable, Sendable, Equatable {
    public var carouselID: String
    public var compositionSeed: String
    public var runID: String
    public var engine: String?
    public var assetIDs: [AssetID]
    public init(carouselID: String, compositionSeed: String, runID: String, engine: String? = nil, assetIDs: [AssetID] = []) {
        self.carouselID = carouselID; self.compositionSeed = compositionSeed; self.runID = runID
        self.engine = engine; self.assetIDs = assetIDs
    }
    enum CodingKeys: String, CodingKey { case carouselID, compositionSeed, runID, engine, assetIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(carouselID: try c.decode(String.self, forKey: .carouselID),
                  compositionSeed: try c.decode(String.self, forKey: .compositionSeed),
                  runID: try c.decode(String.self, forKey: .runID),
                  engine: try c.decodeIfPresent(String.self, forKey: .engine),
                  assetIDs: try c.decodeIfPresent([AssetID].self, forKey: .assetIDs) ?? [])
    }
}

public struct EvalPair: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable, CaseIterable { case split, selection, cover, layout, engine }
    public var pairID: String
    public var runID: String
    public var stage: Stage
    public var left: CandidateRef
    public var right: CandidateRef
    public init(pairID: String, runID: String, stage: Stage = .layout, left: CandidateRef, right: CandidateRef) {
        self.pairID = pairID; self.runID = runID; self.stage = stage; self.left = left; self.right = right
    }
    enum CodingKeys: String, CodingKey { case pairID, runID, stage, left, right }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairID = try c.decode(String.self, forKey: .pairID); runID = try c.decode(String.self, forKey: .runID)
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .layout
        left = try c.decode(CandidateRef.self, forKey: .left); right = try c.decode(CandidateRef.self, forKey: .right)
    }
}

public struct EvalSet: Codable, Sendable, Equatable {
    public var seed: String
    public var createdAt: Date
    public var runs: [String]
    public var pairs: [EvalPair]
    public var strips: [String: String]
    public var versions: [String: String]
    /// Absent in evaluation sets created before template-first availability was checked.
    public var skippedOptions: Int?
    public init(seed: String, createdAt: Date, runs: [String], pairs: [EvalPair], strips: [String: String], versions: [String: String], skippedOptions: Int? = nil) {
        self.seed = seed; self.createdAt = createdAt; self.runs = runs; self.pairs = pairs; self.strips = strips; self.versions = versions
        self.skippedOptions = skippedOptions
    }
}

public struct EvalLabel: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case left, right, tie, neither }
    public var pairID: String
    public var rater: String
    public var choice: Choice
    public var shownLeft: CandidateRef
    public var decidedAt: Date
    public var versions: [String: String]
    public init(pairID: String, rater: String, choice: Choice, shownLeft: CandidateRef, decidedAt: Date, versions: [String: String]) {
        self.pairID = pairID; self.rater = rater; self.choice = choice; self.shownLeft = shownLeft; self.decidedAt = decidedAt; self.versions = versions
    }
}

public struct EvalReport: Codable, Sendable {
    public struct StageSummary: Codable, Sendable {
        public var stage: EvalPair.Stage
        public var agreement: Double
        public var neitherRate: Double
        public var labelledPairs: Int
        public var neither: Int
        public init(stage: EvalPair.Stage, agreement: Double, neitherRate: Double, labelledPairs: Int, neither: Int) {
            self.stage = stage; self.agreement = agreement; self.neitherRate = neitherRate; self.labelledPairs = labelledPairs; self.neither = neither
        }
    }
    public struct Event: Codable, Sendable {
        public var event: String
        public var agreement: Double
        public var labelledPairs: Int
        public var ties: Int
        public init(event: String, agreement: Double, labelledPairs: Int, ties: Int) {
            self.event = event; self.agreement = agreement; self.labelledPairs = labelledPairs; self.ties = ties
        }
    }
    public var agreement: Double
    public var confidenceInterval: [Double]
    public var labelledPairs: Int
    public var ties: Int
    public var events: [Event]
    public var stages: [StageSummary]
    public init(agreement: Double, confidenceInterval: [Double], labelledPairs: Int, ties: Int, events: [Event], stages: [StageSummary] = []) {
        self.agreement = agreement; self.confidenceInterval = confidenceInterval; self.labelledPairs = labelledPairs; self.ties = ties; self.events = events; self.stages = stages
    }
}

public struct EvalRating: Codable, Sendable, Equatable {
    public var runID: String
    public var optionID: String
    public var engine: String
    public var rating: String
    public var rater: String
    public init(runID: String, optionID: String, engine: String, rating: String, rater: String) {
        self.runID = runID; self.optionID = optionID; self.engine = engine; self.rating = rating; self.rater = rater
    }
}
