import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TempDirectory {
    public let url: URL
    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ak14-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func sub(_ name: String) throws -> URL {
        let u = url.appending(path: name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public func remove() { try? FileManager.default.removeItem(at: url) }
}

public enum FixtureFactory {
    public struct Exif: Sendable {
        public var date: String? = "2026:05:29 17:30:03"
        public var offset: String? = "+05:30"
        public var latitude: Double? = 15.4989
        public var longitude: Double? = 73.8278
        public var model: String? = "iPhone 17"
        public var orientation: Int = 1
        public var userComment: String? = nil
        public init() {}
    }

    /// Writes a JPEG filled with `gray` plus a darker block so images have some structure.
    public static func writeJPEG(to url: URL, width: Int = 400, height: Int = 300,
                                 gray: Double = 0.5, exif: Exif = Exif()) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: gray * 0.3, green: gray * 0.5, blue: gray * 0.7, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 3, height: height / 3))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }

        var exifDict: [CFString: Any] = [:]
        if let d = exif.date { exifDict[kCGImagePropertyExifDateTimeOriginal] = d }
        if let o = exif.offset { exifDict[kCGImagePropertyExifOffsetTimeOriginal] = o }
        if let c = exif.userComment { exifDict[kCGImagePropertyExifUserComment] = c }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: exif.orientation,
                                      kCGImagePropertyExifDictionary: exifDict]
        if let m = exif.model { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFModel: m] }
        if let lat = exif.latitude, let lon = exif.longitude {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            ]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func writeBytes(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
