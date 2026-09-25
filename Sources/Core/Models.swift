import Foundation

public struct AssetID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(sha256Hex: String) { self.rawValue = "a_" + sha256Hex.prefix(16) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func < (l: AssetID, r: AssetID) -> Bool { l.rawValue < r.rawValue }
}

public struct GeoPoint: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public struct CaptureMetadata: Codable, Sendable, Equatable {
    public var capturedAt: Date?
    public var timeZoneAssumed: Bool
    /// Exact coordinates. In memory only: run artifacts store `hasLocation` instead (see `redactingLocation()`).
    public var location: GeoPoint?
    public var hasLocation: Bool
    public var cameraModel: String?
    public var isScreenshot: Bool
    public init(capturedAt: Date? = nil, timeZoneAssumed: Bool = false, location: GeoPoint? = nil,
                cameraModel: String? = nil, isScreenshot: Bool = false) {
        self.capturedAt = capturedAt; self.timeZoneAssumed = timeZoneAssumed; self.location = location
        self.hasLocation = location != nil; self.cameraModel = cameraModel; self.isScreenshot = isScreenshot
    }
}

public enum PhotoOrientation: String, Codable, Sendable { case portrait, landscape, square }

public struct PhotoRecord: Codable, Sendable, Equatable, Identifiable {
    public let assetID: AssetID
    public let contentSHA256: String
    /// Paths relative to the ingested folder. More than one entry means exact byte duplicates.
    public var sourceRelativePaths: [String]
    public let byteCount: Int
    /// UTType identifier, e.g. "public.heic".
    public let fileType: String
    /// Dimensions after applying EXIF orientation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let exifOrientation: Int
    public let metadata: CaptureMetadata

    public init(assetID: AssetID, contentSHA256: String, sourceRelativePaths: [String], byteCount: Int,
                fileType: String, pixelWidth: Int, pixelHeight: Int, exifOrientation: Int, metadata: CaptureMetadata) {
        self.assetID = assetID; self.contentSHA256 = contentSHA256; self.sourceRelativePaths = sourceRelativePaths
        self.byteCount = byteCount; self.fileType = fileType; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.exifOrientation = exifOrientation; self.metadata = metadata
    }

    public var id: AssetID { assetID }

    /// Copy safe to write into run artifacts: coordinates dropped, `hasLocation` kept.
    public func redactingLocation() -> PhotoRecord {
        var metadata = self.metadata
        metadata.location = nil
        return PhotoRecord(assetID: assetID, contentSHA256: contentSHA256, sourceRelativePaths: sourceRelativePaths,
                           byteCount: byteCount, fileType: fileType, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                           exifOrientation: exifOrientation, metadata: metadata)
    }
    public var orientation: PhotoOrientation {
        pixelHeight > pixelWidth ? .portrait : pixelWidth > pixelHeight ? .landscape : .square
    }
}

public enum SkipReason: String, Codable, Sendable, CaseIterable {
    case unsupportedType, video, decodeFailure, hiddenFile, directory, unreadable
}

public struct SkippedFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let reason: SkipReason
    public let detail: String?
    public init(relativePath: String, reason: SkipReason, detail: String? = nil) {
        self.relativePath = relativePath; self.reason = reason; self.detail = detail
    }
}

public struct IngestResult: Codable, Sendable, Equatable {
    /// Sorted by assetID.
    public var photos: [PhotoRecord]
    /// Sorted by relativePath.
    public var skipped: [SkippedFile]
    public init(photos: [PhotoRecord], skipped: [SkippedFile]) { self.photos = photos; self.skipped = skipped }
}
