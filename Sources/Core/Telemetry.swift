import Foundation

public struct ProviderCallRecord: Codable, Sendable, Equatable {
    public var stage: String            // triage | planner | repair | retry | mutation
    public var model: String
    public var promptVersion: String
    public var inputTokens = 0, cachedTokens = 0, outputTokens = 0, reasoningTokens = 0
    public var imageCount = 0, thumbnailBytes = 0
    public var latencySeconds = 0.0
    public var retryCount = 0
    public var estimatedCost = 0.0
    public var candidateCount = 0, conceptCount = 0
    public var ok = false
    public var error: String?
    public var responseID: String?

    public init(stage: String, model: String, promptVersion: String) {
        self.stage = stage; self.model = model; self.promptVersion = promptVersion
    }
}
