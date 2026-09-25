import Foundation

public struct IngestOptions: Sendable, Equatable {
    public var recursive: Bool
    public init(recursive: Bool = false) { self.recursive = recursive }
}

public protocol PhotoIngesting: Sendable {
    func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult
}

public protocol PhotoAnalyzing: Sendable {
    /// Never throws: per-feature failures are recorded in `PhotoFeatures.failures`.
    func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures
}
