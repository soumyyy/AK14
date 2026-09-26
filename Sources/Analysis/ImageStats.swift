import CoreGraphics
import Core

extension UnitRect {
    /// Converts a Vision normalized rect (bottom-left origin) to top-left origin, clamped to 0...1.
    public init(visionRect r: CGRect) {
        let x = min(max(Double(r.minX), 0), 1)
        let y = min(max(1 - Double(r.maxY), 0), 1)
        self.init(x: x, y: y,
                  width: min(max(Double(r.width), 0), 1 - x),
                  height: min(max(Double(r.height), 0), 1 - y))
    }
}

public enum ImageStats {
    /// Mean luma (0...1) and fraction of pixels darker than 0.06, measured on a 32x32 gray downsample.
    public static func luminance(of image: CGImage) -> (mean: Double, darkFraction: Double)? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let dark = Double(values.filter { $0 < 0.06 }.count) / Double(values.count)
        return (mean, dark)
    }

    /// Variance of a 3x3 Laplacian over a 256x256 gray downsample, divided by 1000 and clamped to 0...1.
    public static func sharpness(of image: CGImage) -> Double? {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let lap = Double(pixels[i - side]) + Double(pixels[i + side]) + Double(pixels[i - 1])
                    + Double(pixels[i + 1]) - 4 * Double(pixels[i])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        let mean = sum / n
        return min(max((sumSq / n - mean * mean) / 1000, 0), 1)
    }

    /// Mean Lab colour, saturation, warmth and luma contrast on a 32×32 sRGB downsample.
    public static func color(of image: CGImage) -> ColorProfile? {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let n = Double(side * side)
        var r = 0.0, g = 0.0, b = 0.0, sat = 0.0, luma: [Double] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let pr = Double(px[i]) / 255, pg = Double(px[i + 1]) / 255, pb = Double(px[i + 2]) / 255
            r += pr; g += pg; b += pb
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            sat += mx > 0 ? (mx - mn) / mx : 0
            luma.append(0.2126 * pr + 0.7152 * pg + 0.0722 * pb)
        }
        r /= n; g /= n; b /= n
        let meanLuma = luma.reduce(0, +) / n
        let contrast = (luma.map { ($0 - meanLuma) * ($0 - meanLuma) }.reduce(0, +) / n).squareRoot()
        let lab = Self.lab(r, g, b)
        return ColorProfile(l: lab.0, a: lab.1, b: lab.2, saturation: sat / n, warmth: r - b, contrast: contrast)
    }

    /// sRGB (0...1) to CIELAB (D65).
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (R, G, B) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}
