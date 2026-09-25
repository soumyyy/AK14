import Foundation

/// Per-photo feature cache. Key = content SHA-256 + analyzer version, so renames never invalidate it.
public struct AnalysisCache: Sendable {
    public let root: URL
    public let analyzerVersion: String

    public init(root: URL, analyzerVersion: String) {
        self.root = root; self.analyzerVersion = analyzerVersion
    }

    public func url(sha: String) -> URL {
        root.appending(path: "features/\(analyzerVersion)/\(sha).json")
    }

    /// Missing or unreadable entries are treated as misses.
    public func load(sha: String) -> PhotoFeatures? {
        guard let data = try? Data(contentsOf: url(sha: sha)) else { return nil }
        return try? JSONCoding.decoder.decode(PhotoFeatures.self, from: data)
    }

    public func store(_ features: PhotoFeatures, sha: String) throws {
        let target = url(sha: sha)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(features).write(to: target, options: .atomic)
    }
}
