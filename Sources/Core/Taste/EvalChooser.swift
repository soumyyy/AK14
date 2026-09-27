import Foundation

public protocol EvalChooser: Sendable {
    func prefersLeft(_ leftScore: Double, _ rightScore: Double) -> Bool?
}

public struct ComposerEvalChooser: EvalChooser {
    public init() {}
    public func prefersLeft(_ leftScore: Double, _ rightScore: Double) -> Bool? {
        guard leftScore.isFinite, rightScore.isFinite, leftScore != rightScore else { return nil }
        return leftScore < rightScore
    }
}

public struct JudgeResult: Codable, Sendable, Equatable {
    public var directionID: String
    public var candidateFingerprints: [String]
    public var stripSHA256: [String]
    public var winnerIndex: Int?
    public var ranking: [Int]
    public var orderRankings: [[Int]]
    public var reasons: [String]
    public var model: String
    public var promptVersion: String
    public var costUSD: Double
    public var latency: Double
    public var skipped: String?

    public init(directionID: String, candidateFingerprints: [String], stripSHA256: [String] = [], winnerIndex: Int? = nil, ranking: [Int] = [], orderRankings: [[Int]] = [], reasons: [String] = [],
                model: String, promptVersion: String, costUSD: Double = 0, latency: Double = 0, skipped: String? = nil) {
        self.directionID = directionID; self.candidateFingerprints = candidateFingerprints; self.stripSHA256 = stripSHA256; self.winnerIndex = winnerIndex; self.ranking = ranking; self.orderRankings = orderRankings; self.reasons = reasons
        self.model = model; self.promptVersion = promptVersion; self.costUSD = costUSD; self.latency = latency; self.skipped = skipped
    }
}
