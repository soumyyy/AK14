import Core
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RenderError: Error, CustomStringConvertible {
    case missingPhoto(AssetID), decodeFailed(String), encodeFailed(String)
    public var description: String {
        switch self {
        case .missingPhoto(let id): "no source photo for \(id)"
        case .decodeFailed(let p): "could not decode \(p)"
        case .encodeFailed(let p): "could not write \(p)"
        }
    }
}

/// Deterministic renderer for Plain Dump plans: one photo per slide.
/// full_bleed = face/saliency-safe cover crop; hero = whole photo on a paper background with margins.
public struct PlainRenderer: Sendable {
    public static let version = "plain-1"
    static let paper = CGColor(srgbRed: 0.957, green: 0.945, blue: 0.918, alpha: 1)

    public init() {}

    /// Returns slide file names in order (slide-01.png, …) written into `outputDirectory`.
    public func render(plan: CarouselPlan, aspect: CarouselAspect, photos: [AssetID: PhotoRecord],
                       features: [AssetID: PhotoFeatures], sourceFolder: URL, outputDirectory: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let width = aspect.exportWidth, height = aspect.exportHeight
        var names: [String] = []
        for (i, slide) in plan.slides.enumerated() {
            guard let element = slide.photos.first, let record = photos[element.assetID] else {
                throw RenderError.missingPhoto(slide.photos.first?.assetID ?? AssetID(rawValue: "?"))
            }
            let source = sourceFolder.appending(path: record.sourceRelativePaths[0])
            let image = try decode(source, maxPixel: 2 * max(width, height))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw RenderError.encodeFailed("context")
            }
            ctx.interpolationQuality = .high
            let canvas = CGRect(x: 0, y: 0, width: width, height: height)
            if slide.primitive == .hero {
                ctx.setFillColor(Self.paper); ctx.fill(canvas)
                ctx.draw(image, in: Self.fit(image, into: canvas.insetBy(dx: Double(width) * 0.06, dy: Double(height) * 0.06)))
            } else {
                let crop = Self.coverCrop(imageWidth: image.width, imageHeight: image.height,
                                          targetAspect: Double(width) / Double(height), features: features[record.assetID])
                guard let cropped = image.cropping(to: crop) else { throw RenderError.decodeFailed(source.lastPathComponent) }
                ctx.draw(cropped, in: canvas)
            }
            let name = String(format: "slide-%02d.png", i + 1)
            try writePNG(ctx.makeImage()!, to: outputDirectory.appending(path: name))
            names.append(name)
        }
        return names
    }

    /// Cover crop (top-left pixel coordinates) centred on faces, else the largest salient region, else the centre.
    static func coverCrop(imageWidth w: Int, imageHeight h: Int, targetAspect a: Double, features: PhotoFeatures?) -> CGRect {
        let W = Double(w), H = Double(h)
        let (cw, ch) = W / H > a ? (H * a, H) : (W, W / a)
        var focus: CGRect? = nil
        let faces = features?.faces.map(\.box) ?? []
        if !faces.isEmpty {
            let rects = faces.map { CGRect(x: $0.x * W, y: $0.y * H, width: $0.width * W, height: $0.height * H) }
            focus = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        } else if let s = features?.salientRegions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            focus = CGRect(x: s.x * W, y: s.y * H, width: s.width * W, height: s.height * H)
        }
        let f = focus ?? CGRect(x: W / 2, y: H / 2, width: 0, height: 0)
        var x = f.midX - cw / 2, y = f.midY - ch / 2
        // Faces taller than the window: keep their top edge (with a little headroom) rather than cutting heads.
        if !faces.isEmpty && f.height > ch { y = f.minY - ch * 0.05 }
        x = min(max(0, x), W - cw); y = min(max(0, y), H - ch)
        return CGRect(x: x.rounded(), y: y.rounded(), width: cw.rounded(.down), height: ch.rounded(.down))
    }

    static func fit(_ image: CGImage, into box: CGRect) -> CGRect {
        let scale = min(box.width / Double(image.width), box.height / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    func decode(_ url: URL, maxPixel: Int) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw RenderError.decodeFailed(url.lastPathComponent)
        }
        return image
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed(url.lastPathComponent) }
    }
}
