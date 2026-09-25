import Foundation

public struct IngestOptions: Sendable, Equatable {
    public var recursive: Bool
    /// Directories never ingested (e.g. the tool's own runs/cache when they sit inside the input folder).
    public var excludedDirectories: [URL]
    public init(recursive: Bool = false, excludedDirectories: [URL] = []) {
        self.recursive = recursive; self.excludedDirectories = excludedDirectories
    }
}

public enum IngestError: Error, Equatable, CustomStringConvertible {
    case notADirectory(String)
    public var description: String {
        switch self { case .notADirectory(let name): "'\(name)' is not a folder" }
    }
}

public protocol PhotoIngesting: Sendable {
    func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult
}

public protocol PhotoAnalyzing: Sendable {
    /// Never throws: per-feature failures are recorded in `PhotoFeatures.failures`.
    func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures
}
