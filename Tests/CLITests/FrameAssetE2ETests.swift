import Core
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Render

@Test func frameAssetsDecodeAndFrameLayersRenderDeterministically() throws {
    let definitions = FrameAssetRegistry.all
    #expect(definitions.count == 84)
    for frame in definitions {
        let image = try #require(FrameAssetRegistry.image(imageAssetID: frame.imageAssetID), "missing image \(frame.id)")
        #expect(image.width == frame.imageWidth && image.height == frame.imageHeight)
        #expect(frame.photoWindow.x >= 0 && frame.photoWindow.y >= 0)
        #expect(frame.photoWindow.width > 0 && frame.photoWindow.height > 0)
        #expect(frame.photoWindow.x + frame.photoWindow.width <= 1.000001)
        #expect(frame.photoWindow.y + frame.photoWindow.height <= 1.000001)
        #expect(frame.windowAspect > 0)
    }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "frame-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let source = tmp.appending(path: "photo.png")
    let photoContext = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    photoContext.setFillColor(CGColor(srgbRed: 0.1, green: 0.85, blue: 0.25, alpha: 1))
    photoContext.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    let photoImage = photoContext.makeImage()!
    let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, photoImage, nil); CGImageDestinationFinalize(destination)
    let photoID = AssetID(rawValue: "frame-e2e-photo")
    let record = PhotoRecord(assetID: photoID, contentSHA256: "fixture", sourceRelativePaths: ["photo.png"], byteCount: 0,
                             fileType: "public.png", pixelWidth: 128, pixelHeight: 128, exifOrientation: 1, metadata: CaptureMetadata())
    let frame = try #require(definitions.first { $0.category == "film" })
    let layer = DocumentLayer(id: "frame", kind: .frame, frame: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                              slideHint: 0, assetID: photoID, crop: UnitRect(x: 0, y: 0, width: 1, height: 1),
                              frameAssetID: frame.imageAssetID)
    let document = CanvasDocument(id: "frame-e2e", aspect: .square, slideCount: 1, background: .colour("#FFFFFF"), layers: [layer])
    let renderer = DocumentRenderer()
    let first = tmp.appending(path: "first"), second = tmp.appending(path: "second")
    let outcome1 = try renderer.render(document, photos: [photoID: record], sourceFolder: tmp, outputDirectory: first)
    let outcome2 = try renderer.render(document, photos: [photoID: record], sourceFolder: tmp, outputDirectory: second)
    #expect(outcome1.failures.isEmpty && outcome2.failures.isEmpty)
    let one = try Data(contentsOf: first.appending(path: try #require(outcome1.names.first)))
    let two = try Data(contentsOf: second.appending(path: try #require(outcome2.names.first)))
    #expect(one == two)
    let outputSource = CGImageSourceCreateWithData(one as CFData, nil)!
    let output = CGImageSourceCreateImageAtIndex(outputSource, 0, nil)!
    let pixels = try #require(output.dataProvider?.data)
    let bytes = CFDataGetBytePtr(pixels)!
    let w = output.width, h = output.height, window = frame.photoWindow
    let doc = layer.frame
    let cx = Int((doc.x + (window.x + window.width / 2) * doc.width) * Double(w))
    let cy = Int((doc.y + (window.y + window.height / 2) * doc.height) * Double(h))
    let inside = (cy * w + cx) * 4
    #expect(bytes[inside + 1] > bytes[inside] && bytes[inside + 1] > bytes[inside + 2], "photo should be visible in the frame window")
    let ox = Int((doc.x + 0.01) * Double(w)), oy = Int((doc.y + 0.01) * Double(h)), outside = (oy * w + ox) * 4
    #expect(bytes[outside] != 26 || bytes[outside + 1] != 217 || bytes[outside + 2] != 64,
            "frame artwork should cover pixels outside the photo window")
}
