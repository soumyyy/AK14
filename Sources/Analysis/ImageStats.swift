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
}
