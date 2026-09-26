import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
    fatalError("Could not create icon canvas")
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: 1)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, _ hex: UInt32) {
    context.addPath(path)
    context.setFillColor(color(hex))
    context.fillPath()
}

func gradient(_ rect: CGRect, top: UInt32, bottom: UInt32) {
    let colors = [color(top), color(bottom)] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                              end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

// Deep evergreen gives the light photo card a clear silhouette on the Home Screen.
gradient(CGRect(x: 0, y: 0, width: side, height: side), top: 0x315B50, bottom: 0x153B36)

let card = CGRect(x: 184, y: 132, width: 656, height: 760)
let cardPath = rounded(card, radius: 76)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 38, color: color(0x0A201C).copy(alpha: 0.32))
fill(cardPath, 0xF6F2E8)
context.restoreGState()

let photo = CGRect(x: 240, y: 356, width: 544, height: 464)
context.saveGState()
context.addPath(rounded(photo, radius: 42))
context.clip()
gradient(photo, top: 0xE9A982, bottom: 0xF4D49A)

// Setting sun, framed by two calm, overlapping ridgelines.
context.setFillColor(color(0xFFE19A))
context.fillEllipse(in: CGRect(x: 626, y: 650, width: 94, height: 94))

let farRidge = CGMutablePath()
farRidge.move(to: CGPoint(x: photo.minX, y: 500))
farRidge.addCurve(to: CGPoint(x: photo.maxX, y: 505), control1: CGPoint(x: 400, y: 620), control2: CGPoint(x: 640, y: 610))
farRidge.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
farRidge.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
farRidge.closeSubpath()
fill(farRidge, 0xC9795F)

let nearRidge = CGMutablePath()
nearRidge.move(to: CGPoint(x: photo.minX, y: 432))
nearRidge.addCurve(to: CGPoint(x: photo.maxX, y: 440), control1: CGPoint(x: 416, y: 532), control2: CGPoint(x: 622, y: 524))
nearRidge.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
nearRidge.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
nearRidge.closeSubpath()
fill(nearRidge, 0x367966)

let foreground = CGMutablePath()
foreground.move(to: CGPoint(x: photo.minX, y: 356))
foreground.addCurve(to: CGPoint(x: photo.maxX, y: 384), control1: CGPoint(x: 400, y: 434), control2: CGPoint(x: 650, y: 458))
foreground.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
foreground.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
foreground.closeSubpath()
fill(foreground, 0x205B4B)
context.restoreGState()

// A quiet caption line and three slide marks make the photo read as part of a story.
fill(rounded(CGRect(x: 246, y: 258, width: 254, height: 18), radius: 9), 0x284940)
fill(rounded(CGRect(x: 246, y: 218, width: 142, height: 12), radius: 6), 0xAAB7A9)
context.setFillColor(color(0x315B50))
context.fillEllipse(in: CGRect(x: 642, y: 209, width: 20, height: 20))
context.setFillColor(color(0xAAB7A9))
context.fillEllipse(in: CGRect(x: 682, y: 213, width: 12, height: 12))
context.fillEllipse(in: CGRect(x: 712, y: 213, width: 12, height: 12))

let output: URL
if CommandLine.arguments.count > 1 {
    output = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/iOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination at \(output.path)")
}
CGImageDestinationAddImage(destination, image, [kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
                                                kCGImagePropertyProfileName: "sRGB IEC61966-2.1"] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app icon") }
print("Wrote \(side)×\(side) app icon to \(output.path)")
