import Foundation

public struct CandidateRef: Codable, Sendable, Equatable {
    public var carouselID: String
    public var compositionSeed: String
    public var runID: String
    public init(carouselID: String, compositionSeed: String, runID: String) {
        self.carouselID = carouselID; self.compositionSeed = compositionSeed; self.runID = runID
    }
}

public struct EvalPair: Codable, Sendable, Equatable {
    public var pairID: String
    public var runID: String
    public var left: CandidateRef
    public var right: CandidateRef
    public init(pairID: String, runID: String, left: CandidateRef, right: CandidateRef) {
        self.pairID = pairID; self.runID = runID; self.left = left; self.right = right
    }
}

public struct EvalSet: Codable, Sendable, Equatable {
    public var seed: String
    public var createdAt: Date
    public var runs: [String]
    public var pairs: [EvalPair]
    public var strips: [String: String]
    public var versions: [String: String]
    public init(seed: String, createdAt: Date, runs: [String], pairs: [EvalPair], strips: [String: String], versions: [String: String]) {
        self.seed = seed; self.createdAt = createdAt; self.runs = runs; self.pairs = pairs; self.strips = strips; self.versions = versions
    }
}

public struct EvalLabel: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case left, right, tie }
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
    public init(agreement: Double, confidenceInterval: [Double], labelledPairs: Int, ties: Int, events: [Event]) {
        self.agreement = agreement; self.confidenceInterval = confidenceInterval; self.labelledPairs = labelledPairs; self.ties = ties; self.events = events
    }
}
