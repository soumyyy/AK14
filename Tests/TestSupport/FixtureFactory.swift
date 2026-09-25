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

    /// Writes a visually distinct "scene": a hue-coloured background with shapes placed by `scene`.
    public static func writeScene(to url: URL, scene: Int, exif: Exif = Exif()) throws {
        let width = 400, height = 300
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var rng = SplitMix(seed: UInt64(scene) &* 7919 &+ 17)
        func color() -> CGColor { CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1) }
        ctx.setFillColor(color()); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<(6 + scene % 5) {
            ctx.setFillColor(color())
            let r = CGRect(x: rng.unit() * 360, y: rng.unit() * 260, width: 20 + rng.unit() * 160, height: 20 + rng.unit() * 140)
            if i % 2 == 0 { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
        }
        try write(ctx.makeImage()!, to: url, exif: exif)
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
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
        try write(ctx.makeImage()!, to: url, exif: exif)
    }

    static func write(_ image: CGImage, to url: URL, exif: Exif) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
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
