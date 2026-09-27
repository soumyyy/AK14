import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum KitPreview {
    public static func renderSheet(to url: URL) throws {
        let columns = 6, cellW = 220, cellH = 175
        let rows = (KitAssetRegistry.all.count + columns - 1) / columns
        let width = columns * cellW, height = rows * cellH
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.encodeFailed(url.path)
        }
        // sheet background: warm off-white studio backdrop
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.91, blue: 0.87, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, asset) in KitAssetRegistry.all.enumerated() {
            let col = index % columns, row = index / columns
            let x = col * cellW, y = row * cellH
            let cell = CGRect(x: x, y: y, width: cellW, height: cellH)
            let isOverlay = [.lightLeak, .grain, .dust].contains(asset.category)

            // cell card
            let cardInset: CGFloat = 6
            let card = cell.insetBy(dx: cardInset, dy: cardInset)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.16))
            let cardPath = CGPath(roundedRect: card, cornerWidth: 8, cornerHeight: 8, transform: nil)
            if isOverlay {
                context.addPath(cardPath); context.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                    CGColor(gray: 0.38, alpha: 1), CGColor(gray: 0.58, alpha: 1)
                ] as CFArray, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: CGPoint(x: card.minX, y: card.minY), end: CGPoint(x: card.maxX, y: card.maxY), options: [])
            } else {
                context.setFillColor(CGColor(srgbRed: 0.985, green: 0.975, blue: 0.95, alpha: 1))
                context.addPath(cardPath); context.fillPath()
            }
            context.restoreGState()
            context.saveGState()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); context.setLineWidth(1)
            context.addPath(cardPath); context.strokePath()
            context.restoreGState()

            // asset area: fit the asset's own aspect ratio inside a sensible box, centred
            let labelHeight: CGFloat = 20
            let maxBox = CGRect(x: card.minX + 10, y: card.minY + labelHeight, width: card.width - 20, height: card.height - labelHeight - 10)
            let assetRect: CGRect
            if isOverlay {
                // overlays are shown full-bleed within a photo-sized box so their effect reads clearly
                assetRect = maxBox
            } else {
                let aspect = asset.aspect
                var w = maxBox.width, h = w / aspect
                if h > maxBox.height { h = maxBox.height; w = h * aspect }
                assetRect = CGRect(x: maxBox.midX - w / 2, y: maxBox.midY - h / 2, width: w, height: h)
            }
            asset.draw(in: context, rect: assetRect, seed: UInt64(index + 1))

            // label, centred beneath the asset
            let text = asset.id as CFString
            let font = CTFontCreateWithName("Helvetica" as CFString, 10.5, nil)
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.22, alpha: 1)] as CFDictionary
            let attrString = CFAttributedStringCreate(nil, text, attrs)!
            let line = CTLineCreateWithAttributedString(attrString)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: card.midX - lineWidth / 2, y: card.minY + 7)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed(url.path) }
    }
}
