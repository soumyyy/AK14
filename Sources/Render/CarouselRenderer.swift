import Core
import CoreImage
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RenderError: Error, CustomStringConvertible {
    case missingPhoto(AssetID), decodeFailed(String), encodeFailed(String), missingFont
    public var description: String {
        switch self {
        case .missingPhoto(let id): "no source photo for \(id)"
        case .decodeFailed(let p): "could not decode \(p)"
        case .encodeFailed(let p): "could not write \(p)"
        case .missingFont: "bundled stamp font is missing"
        }
    }
}

/// Draws resolved slides deterministically: same layout + sources + seed → same PNG bytes.
public struct CarouselRenderer: Sendable {
    public static let version = "render-2"
    static let paperColor = CGColor(srgbRed: 0.957, green: 0.945, blue: 0.918, alpha: 1)
    private static let washContext = CIContext(options: [.useSoftwareRenderer: true])

    public struct Outcome: Sendable {
        /// Slide file names written, in slide order (slide-01.png, …).
        public var names: [String] = []
        /// One message per slide that failed; the other slides still render.
        public var failures: [String] = []
    }

    public init() {}

    public func render(_ carousel: ResolvedCarousel, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                       outputDirectory: URL) throws -> Outcome {
        let document = CanvasDocument(from: carousel, photos: photos)
        return try DocumentRenderer().render(document, photos: photos, sourceFolder: sourceFolder, outputDirectory: outputDirectory)
    }

    func legacyRender(_ carousel: ResolvedCarousel, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                      outputDirectory: URL) throws -> Outcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var outcome = Outcome()
        let seed = UInt64(carousel.seed, radix: 16) ?? 0
        for slide in carousel.slides {
            let name = String(format: "slide-%02d.png", slide.index + 1)
            do {
                let image = try renderSlide(slide, aspect: carousel.aspect, photos: photos, sourceFolder: sourceFolder,
                                            seed: seed &+ UInt64(slide.index) &* 0x9E37)
                try Self.writePNG(image, to: outputDirectory.appending(path: name))
                outcome.names.append(name)
            } catch {
                outcome.failures.append("slide \(slide.index + 1): \(error)")
            }
        }
        return outcome
    }

    func renderSlide(_ slide: ResolvedSlide, aspect: CarouselAspect, photos: [AssetID: PhotoRecord],
                     sourceFolder: URL, seed: UInt64) throws -> CGImage {
        let W = aspect.exportWidth, H = aspect.exportHeight
        let short = Double(min(W, H))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RenderError.encodeFailed("context")
        }
        ctx.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        var rng = SeededRandom(seed: seed)

        // Background
        ctx.setFillColor(Self.paperColor); ctx.fill(canvas)
        if slide.background == "paper" { StyleLayer.paper(ctx, size: canvas.size, rng: &rng) }
        if slide.background.hasPrefix("wash:"),
           let rawID = slide.background.split(separator: ":").dropFirst().first.map(String.init),
           let record = photos[AssetID(rawValue: rawID)] {
            let source = sourceFolder.appending(path: record.sourceRelativePaths[0])
            if let base = try? Self.decodeCropped(source, record: record, crop: UnitRect(x: 0, y: 0, width: 1, height: 1),
                                                  frame: CGSize(width: canvas.width * 0.34, height: canvas.height * 0.34)),
               let wash = Self.photoWash(base, size: canvas.size) {
                ctx.draw(wash, in: canvas)
                // Keep the softened scene rich but subordinate to the sharp foreground image.
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.24)); ctx.fill(canvas)
            }
        }

        for e in slide.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            let rect = Self.cgRect(e.frame, W: Double(W), H: Double(H))
            switch e.kind {
            case .photo:
                guard let id = e.assetID, let record = photos[id] else { throw RenderError.missingPhoto(e.assetID ?? AssetID(rawValue: "?")) }
                let source = sourceFolder.appending(path: record.sourceRelativePaths[0])
                let crop = e.crop ?? UnitRect(x: 0, y: 0, width: 1, height: 1)
                var image = try Self.decodeCropped(source, record: record, crop: crop, frame: rect.size)
                if let exposure = e.adjustments?.exposure, exposure != 0 {
                    let input = CIImage(cgImage: image).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
                    if let adjusted = Self.washContext.createCGImage(input, from: input.extent) { image = adjusted }
                }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -e.rotationDegrees * .pi / 180)
                let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
                let border = e.border * short
                if e.shadow {
                    ctx.setShadow(offset: CGSize(width: 0, height: -0.006 * short), blur: 0.022 * short,
                                  color: CGColor(gray: 0, alpha: 0.28))
                }
                if border > 0 {
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(local.insetBy(dx: -border, dy: -border))
                    ctx.setShadow(offset: .zero, blur: 0, color: nil)
                }
                ctx.draw(image, in: local)
                ctx.restoreGState()
            case .tape:
                StyleLayer.tape(ctx, rect: rect, rotationDegrees: e.rotationDegrees, opacity: e.opacity, rng: &rng)
            case .stamp:
                try StampRenderer.draw(ctx, text: e.text ?? "", rect: rect, opacity: e.opacity)
            }
        }

        if slide.filmEdge { StyleLayer.filmEdge(ctx, size: canvas.size) }
        if slide.grain > 0 { StyleLayer.grain(ctx, size: canvas.size, strength: slide.grain, rng: &rng) }
        guard let out = ctx.makeImage() else { throw RenderError.encodeFailed("image") }
        return out
    }

    /// Canvas-normalized top-left rect → Core Graphics (bottom-left) pixel rect.
    static func cgRect(_ u: UnitRect, W: Double, H: Double) -> CGRect {
        CGRect(x: (u.x * W).rounded(), y: (H - (u.y + u.height) * H).rounded(),
               width: (u.width * W).rounded(), height: (u.height * H).rounded())
    }

    /// Reuses the slide's own photograph as a soft, full-canvas color field behind a landscape band.
    /// No new asset or random treatment is involved, so rerenders remain stable.
    static func photoWash(_ image: CGImage, size: CGSize) -> CGImage? {
        let washSize = CGSize(width: max(1, (size.width * 0.34).rounded()), height: max(1, (size.height * 0.34).rounded()))
        let target = CGRect(origin: .zero, size: washSize)
        let input = CIImage(cgImage: image)
        let scale = max(washSize.width / CGFloat(image.width), washSize.height / CGFloat(image.height))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let origin = CGPoint(x: (scaled.extent.width - washSize.width) / -2, y: (scaled.extent.height - washSize.height) / -2)
        let cropped = scaled.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).cropped(to: target)
        let radius = max(1, 34 * washSize.width / 1080)
        let blurred = cropped.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: target)
        return washContext.createCGImage(blurred, from: target)
    }

    /// Decodes the oriented original at just enough resolution for the frame, then crops (top-left crop coords).
    static func decodeCropped(_ url: URL, record: PhotoRecord, crop: UnitRect, frame: CGSize) throws -> CGImage {
        let a = Double(record.pixelWidth) / Double(max(1, record.pixelHeight))
        let needW = frame.width / crop.width, needH = frame.height / crop.height
        let longEdge = a >= 1 ? max(needW, needH * a) : max(needH, needW / a)
        let maxPixel = min(4096, max(256, Int((longEdge * 1.15).rounded(.up))))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw RenderError.decodeFailed(url.lastPathComponent)
        }
        let W = Double(image.width), H = Double(image.height)
        let rect = CGRect(x: (crop.x * W).rounded(), y: (crop.y * H).rounded(),
                          width: max(1, (crop.width * W).rounded(.down)), height: max(1, (crop.height * H).rounded(.down)))
        guard let cropped = image.cropping(to: rect) else { throw RenderError.decodeFailed(url.lastPathComponent) }
        return cropped
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed(url.lastPathComponent) }
    }
}
