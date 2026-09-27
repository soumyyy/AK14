import Core
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct StripRenderer: Sendable {
    public init() {}

    public func strip(slides: [URL], height: Int = 96, quality: Double = 0.7) throws -> Data {
        try strip(groups: [slides], height: height, quality: quality)
    }

    /// Renders photo groups as a single strip, with a clear neutral divider between groups.
    public func strip(groups: [[URL]], height: Int = 96, quality: Double = 0.7) throws -> Data {
        let groups = try groups.filter { !$0.isEmpty }.map { group in
            try group.map { path -> CGImage in
                guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StripError.image(path.path) }
                return image
            }
        }
        let images = groups.flatMap { $0 }
        let widths = images.map { max(1, Int((Double($0.width) * Double(height) / Double($0.height)).rounded())) }
        var groupBreaks = Set<Int>()
        var cumulative = 0
        for group in groups.dropLast() { cumulative += group.count; groupBreaks.insert(cumulative) }
        var gaps = 0
        if images.count > 1 {
            for index in 1..<images.count { gaps += groupBreaks.contains(index) ? 24 : 4 }
        }
        let width = widths.reduce(0, +) + gaps
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw StripError.image("strip")
        }
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for (index, (image, w)) in zip(images, widths).enumerated() {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: x, y: 0, width: w, height: height)); x += w
            if index < images.count - 1 {
                let gap = groupBreaks.contains(index + 1) ? 24 : 4
                if gap > 4 {
                    ctx.setFillColor(CGColor(gray: 0.68, alpha: 1))
                    ctx.fill(CGRect(x: x + gap / 2 - 1, y: height / 6, width: 2, height: height * 2 / 3))
                }
                x += gap
            }
        }
        guard let result = ctx.makeImage() else { throw StripError.image("strip") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw StripError.image("strip") }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StripError.image("strip") }
        return data as Data
    }

    public func strip(_ carousel: ResolvedCarousel, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                      height: Int = 96, quality: Double = 0.7) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = try CarouselRenderer().render(carousel, photos: photos, sourceFolder: sourceFolder, outputDirectory: directory)
        guard outcome.failures.isEmpty else { throw StripError.image(outcome.failures.joined(separator: "; ")) }
        return try strip(slides: outcome.names.map { directory.appending(path: $0) }, height: height, quality: quality)
    }

    private enum StripError: Error { case image(String) }
}
