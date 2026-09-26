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
