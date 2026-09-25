import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailError: Error, Equatable {
    case decodeFailed, encodeFailed
}

/// Orientation-corrected JPEG thumbnails without source metadata, cached by content digest + tier + version.
public struct Thumbnailer: Sendable {
    public static let version = "thumb-1"
    public let cacheRoot: URL

    public init(cacheRoot: URL) { self.cacheRoot = cacheRoot }

    public func url(sha: String, tier: ThumbnailTier) -> URL {
        cacheRoot.appending(path: "thumbnails/\(Self.version)/\(tier.rawValue)/\(sha).jpg")
    }

    public func thumbnail(sha: String, source: URL, tier: ThumbnailTier) throws -> URL {
        let out = url(sha: sha, tier: tier)
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tier.longEdge,
        ]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { throw ThumbnailError.decodeFailed }

        // Write to a temp name, then move, so a crash never leaves a partial file at the cached path.
        let tmp = out.deletingLastPathComponent().appending(path: ".\(sha)-\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ThumbnailError.encodeFailed }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: tier.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            throw ThumbnailError.encodeFailed
        }
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: tmp); return out }
        try fm.moveItem(at: tmp, to: out)
        return out
    }
}
