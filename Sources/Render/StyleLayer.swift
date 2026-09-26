import Core
import CoreGraphics
import Foundation

/// Procedural, seeded decorations (no third-party assets): paper, grain, tape, film edge.
enum StyleLayer {
    /// Soft low-frequency blotches plus fine fibre noise over the base paper colour.
    static func paper(_ ctx: CGContext, size: CGSize, rng: inout SeededRandom) {
        let blotches = noise(width: 48, height: Int(48 * size.height / size.width), blurPasses: 4, rng: &rng)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.setAlpha(0.035); ctx.setBlendMode(.multiply)
        ctx.draw(blotches, in: CGRect(origin: .zero, size: size))
        let fibres = noise(width: Int(size.width / 2), height: Int(size.height / 2), blurPasses: 1, rng: &rng)
        ctx.setAlpha(0.03)
        ctx.draw(fibres, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    static func grain(_ ctx: CGContext, size: CGSize, strength: Double, rng: inout SeededRandom) {
        let n = noise(width: Int(size.width), height: Int(size.height), rng: &rng)
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.overlay); ctx.setAlpha(strength)
        ctx.draw(n, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    /// Translucent tape strip with torn (zig-zag) short ends.
    static func tape(_ ctx: CGContext, rect: CGRect, rotationDegrees: Double, opacity: Double, rng: inout SeededRandom) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: -rotationDegrees * .pi / 180)
        let w = rect.width / 2, h = rect.height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -w, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        let teeth = 5
        for i in 1...teeth {                       // right torn edge, top → bottom
            let y = h - 2 * h * Double(i) / Double(teeth)
            path.addLine(to: CGPoint(x: w - (i % 2 == 0 ? 0 : rng.range(2, 6)), y: y))
        }
        path.addLine(to: CGPoint(x: -w, y: -h))
        for i in 1...teeth {                       // left torn edge, bottom → top
            let y = -h + 2 * h * Double(i) / Double(teeth)
            path.addLine(to: CGPoint(x: -w + (i % 2 == 0 ? 0 : rng.range(2, 6)), y: y))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.87, alpha: opacity))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0.55, alpha: opacity * 0.35)); ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Black film-strip bands down both sides with evenly spaced sprocket holes.
    static func filmEdge(_ ctx: CGContext, size: CGSize) {
        let band = StyleMetrics.filmBand(canvasWidth: size.width)
        let holeW = (0.45 * band).rounded(), holeH = (0.02 * size.height).rounded(), step = (0.04 * size.height).rounded()
        ctx.saveGState()
        for x in [0, size.width - band] {
            ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: band, height: size.height))
            ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.91, blue: 0.86, alpha: 1))
            var y = step / 2
            while y + holeH < size.height {
                let hole = CGRect(x: x + (band - holeW) / 2, y: y, width: holeW, height: holeH)
                ctx.addPath(CGPath(roundedRect: hole, cornerWidth: holeW * 0.2, cornerHeight: holeW * 0.2, transform: nil))
                ctx.fillPath()
                y += step
            }
        }
        ctx.restoreGState()
    }

    /// Seeded grey noise image; each blur pass is a 3x3 box blur, for softer, less blocky texture.
    static func noise(width: Int, height: Int, blurPasses: Int = 0, rng: inout SeededRandom) -> CGImage {
        let w = max(1, width), h = max(1, height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        var i = 0
        while i < bytes.count {
            var v = rng.next()
            for _ in 0..<8 where i < bytes.count { bytes[i] = UInt8(truncatingIfNeeded: v); v >>= 8; i += 1 }
        }
        for _ in 0..<blurPasses {
            var out = bytes
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0, n = 0
                    for dy in -1...1 { for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0 && xx < w && yy >= 0 && yy < h { sum += Int(bytes[yy * w + xx]); n += 1 }
                    } }
                    out[y * w + x] = UInt8(sum / n)
                }
            }
            bytes = out
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
